# frozen_string_literal: true

require "json"
require "securerandom"
require "redis"

module RSpec
  module Hopper
    module Queue
      # The one queue adapter: Redis Streams with a consumer group per unit
      # stream, two Lua scripts (initialization and state transition), and a
      # four-part reservation handle that fences every mutation of an in-flight
      # entry. See docs/DESIGN.md for the contract this implements.
      #
      # The adapter never opens a connection; the caller passes a `Redis`.
      class RedisStreams
        LUA_DIR = File.expand_path("redis_streams/lua", __dir__)
        SCRIPTS = {
          init: File.read(File.join(LUA_DIR, "init.lua")),
          transition: File.read(File.join(LUA_DIR, "transition.lua"))
        }.freeze
        LEASE_SECONDS = 60
        INIT_ERRORS = {
          "LEASE_LOST" => LeaseLost,
          "ALREADY_INITIALIZED" => PreviouslyInitialized,
          "ALREADY_READY" => AlreadyInitialized
        }.freeze
        BUDGET_FIELDS = %i[max_requeues requeue_tolerance max_reclaims timeout ttl].freeze

        attr_reader :redis, :build_id, :keyset, :ttl, :tombstone_ttl, :timeout,
                    :max_requeues, :requeue_tolerance, :max_reclaims

        # Times are seconds; the adapter converts to milliseconds for Redis.
        def initialize(redis:, build_id:, ttl: Config::WORK_DEFAULTS[:ttl],
                       tombstone_ttl: Config::WORK_DEFAULTS[:tombstone_ttl],
                       timeout: Config::WORK_DEFAULTS[:timeout],
                       max_requeues: Config::WORK_DEFAULTS[:max_requeues],
                       requeue_tolerance: Config::WORK_DEFAULTS[:requeue_tolerance],
                       max_reclaims: Config::WORK_DEFAULTS[:max_reclaims])
          @redis = redis
          @build_id = build_id
          @keyset = Keys.new(build_id)
          @ttl = ttl
          @tombstone_ttl = tombstone_ttl
          @timeout = timeout
          @max_requeues = max_requeues
          @requeue_tolerance = requeue_tolerance
          @max_reclaims = max_reclaims
          @shas = {}
        end

        # -- build lifecycle ---------------------------------------------------

        # One MULTI: meta and the tombstone read together so a caller can tell
        # "never initialized" from "initialized, state gone".
        def status
          meta, tombstone = redis.multi do |m|
            m.hgetall(keyset.meta)
            m.exists(keyset.exists)
          end
          meta = nil if meta.empty?
          Status.new(state: meta && meta["state"], tombstone: tombstone.positive?, meta: meta)
        end

        def acquire_leader(worker_id)
          token = "#{worker_id}:#{SecureRandom.hex(8)}"
          redis.set(keyset.leader, token, nx: true, ex: LEASE_SECONDS) ? token : nil
        end

        def initialize_build(token:, manifest:, unit_ids:)
          ids = unit_ids.map { |u| u.respond_to?(:id) ? u.id : u }
          init_script("success", token, manifest, JSON.generate(ids))
          :ready
        end

        def fail_initialization(token:, manifest:)
          init_script("failure", token, manifest, "[]")
          :init_failed
        end

        def manifest
          meta = status.meta
          meta && Manifest.from_meta(meta)
        end

        # -- reservation -------------------------------------------------------

        # Atomically claims one entry idle past `timeout` (priority stream
        # first) and records the reclaim. Returns nil when nothing was claimed
        # or when the script finalized the unit as reclaim_budget_exhausted.
        def reclaim_lost(worker_id)
          reply = check!(transition("reclaim", worker_id, ms(timeout), max_reclaims), :reclaim, nil)
          return nil unless reply.first == "OK"

          _, stream, entry_id, unit_id, unit_type, delivery_count, retry_index, reclaim_count = reply
          Reservation.new(unit_id: unit_id, unit_type: unit_type, stream: stream, entry_id: entry_id,
                          consumer: worker_id, delivery_count: delivery_count,
                          retry_index: retry_index, reclaim_count: reclaim_count)
        end

        # Priority stream without blocking, then units with BLOCK, then delivery
        # accounting. Returns nil on an empty queue or when the entry was
        # reclaimed between the read and the accounting.
        def reserve(worker_id, block_ms: 1000)
          stream, entry_id, fields = read_group(worker_id, "units:priority", nil) ||
                                     read_group(worker_id, "units", block_ms)
          return nil unless entry_id

          reply = transition("delivery_accounting", worker_id, stream, entry_id, fields["id"])
          return nil if reply.first == "STALE"

          check!(reply, :delivery_accounting, fields["id"])
          Reservation.new(unit_id: fields["id"], unit_type: fields["type"], stream: stream, entry_id: entry_id,
                          consumer: worker_id, delivery_count: reply[1],
                          retry_index: reply[2], reclaim_count: reply[3])
        end

        # -- fenced mutations --------------------------------------------------
        # The protocol says these return `true` on success and raise otherwise.
        # rubocop:disable Naming/PredicateMethod

        def heartbeat(reservation)
          fenced(:heartbeat, reservation, reservation.unit_id)
          true
        end

        def finalize(reservation, outcome:, duration_ms:, reason: nil, errors: nil)
          outcome = outcome.to_sym
          raise ArgumentError, "outcome must be one of #{OUTCOMES.join(", ")}" unless OUTCOMES.include?(outcome)
          raise ArgumentError, "reason is required when outcome is failed" if outcome == :failed && reason.nil?
          raise ArgumentError, "unknown reason #{reason}" if reason && !REASONS.include?(reason.to_s)

          fenced(:finalize, reservation, reservation.unit_id, outcome.to_s, duration_ms.to_i,
                 reason.to_s, errors_json(errors))
          true
        end

        def requeue(reservation, duration_ms:, failure_summary:, errors:)
          reply = fenced(:requeue, reservation, reservation.unit_id, reservation.unit_type,
                         max_requeues, requeue_tolerance, duration_ms.to_i, failure_summary.to_s,
                         errors_json(errors))
          status = reply.first == "REQUEUED" ? :requeued : :finalized
          RequeueResult.new(status: status, retry_index: reply[1])
        end

        def record_abandoned(reservation, elapsed_ms:)
          fenced(:abandoned, reservation, reservation.unit_id, elapsed_ms.to_i)
          true
        end

        # -- unfenced writes ---------------------------------------------------

        # Works before initialization: a boot error may precede `ready`.
        def record_worker_error(worker_id:, phase:, error:, unit_id: nil)
          phase = phase.to_s
          raise ArgumentError, "phase must be one of #{PHASES.join(", ")}" unless PHASES.include?(phase)

          event = {
            "type" => "worker_error", "worker_id" => worker_id, "phase" => phase, "unit_id" => unit_id,
            "class" => error.class.name,
            "message" => ErrorPayload.truncate(error.message.to_s, ErrorPayload::MESSAGE_BYTES),
            "backtrace" => (error.backtrace || []).first(ErrorPayload::BACKTRACE_LINES)
          }
          transition("worker_error", worker_id, JSON.generate(event))
          true
        end

        def record_stale_rejected(reservation, operation:)
          event = {
            "type" => "stale_rejected", "unit_id" => reservation.unit_id, "worker_id" => reservation.consumer,
            "retry_index" => reservation.retry_index, "reclaim_count" => reservation.reclaim_count,
            "ownership_generation" => reservation.ownership_generation, "operation" => operation.to_s,
            "stream" => reservation.stream, "entry_id" => reservation.entry_id,
            "delivery_count" => reservation.delivery_count
          }
          transition("stale_rejected", reservation.consumer, JSON.generate(event))
          true
        end

        def touch_liveness(worker_id, current_unit: nil)
          check!(transition("liveness", worker_id, current_unit.to_s), :liveness, current_unit)
          true
        end
        # rubocop:enable Naming/PredicateMethod

        # -- completion --------------------------------------------------------

        def complete?
          finalized, total = meta_fields("finalized_count", "total_units")
          finalized.to_i == total.to_i
        end

        def finalized_count = meta_fields("finalized_count").first.to_i
        def total_units = meta_fields("total_units").first.to_i

        # -- reads -------------------------------------------------------------

        def attempt_events
          redis.xrange(keyset.attempts).map { |_id, fields| JSON.parse(fields["json"]) }
        end

        def workers = json_hash(keyset.workers)
        def unit_states = json_hash(keyset.unit_state)

        # Existing key names of this build, for TTL scans.
        def keys
          found = []
          redis.scan_each(match: keyset.pattern) { |k| found << k }
          found.sort
        end

        private

        def ms(seconds) = (seconds * 1000).to_i

        def json_hash(key)
          redis.hgetall(key).transform_values { |v| JSON.parse(v) }
        end

        def meta_fields(*names)
          values = redis.hmget(keyset.meta, *names)
          raise BuildStateMissing, "build #{build_id}: meta is missing" if values.all?(&:nil?)

          values
        end

        def errors_json(errors)
          return "" if errors.nil?

          JSON.generate(ErrorPayload.cap(errors))
        end

        def budget_meta
          BUDGET_FIELDS.to_h { |f| [f.to_s, public_send(f).to_s] }
        end

        def init_script(mode, token, manifest, unit_ids_json)
          fields = manifest.to_meta.merge(budget_meta)
          argv = [mode, token, ms(ttl), ms(tombstone_ttl), JSON.generate(fields), unit_ids_json, manifest.unit_type]
          run_script(:init, init_keys, argv)
        rescue Redis::CommandError => e
          code = e.message[/\A(?:ERR\s+)?([A-Z_]+)/, 1]
          raise INIT_ERRORS.fetch(code), "build #{build_id}: #{code}" if INIT_ERRORS.key?(code)

          raise
        end

        def init_keys
          [keyset.units, keyset.units_priority, keyset.attempts, keyset.meta, keyset.unit_state,
           keyset.leader, keyset.exists]
        end

        def transition_keys
          [keyset.units, keyset.units_priority, keyset.attempts, keyset.meta, keyset.unit_state, keyset.workers]
        end

        def transition(mode, worker_id, *argv)
          run_script(:transition, transition_keys, [mode, worker_id, ms(ttl), *argv])
        rescue Redis::CommandError => e
          raise CorruptBuild, "build #{build_id}: #{e.message}" if e.message.start_with?("NOGROUP")

          raise
        end

        # Runs a mode carrying the reservation handle and maps STALE/CORRUPT.
        def fenced(mode, reservation, *argv)
          reply = transition(mode.to_s, reservation.consumer, reservation.stream, reservation.entry_id,
                             reservation.delivery_count, *argv)
          check!(reply, mode, reservation.unit_id)
        end

        def check!(reply, operation, unit_id)
          case reply.first
          when "STALE"
            raise StaleReservation, "#{operation} rejected for #{unit_id}: ownership has moved"
          when "CORRUPT"
            raise CorruptBuild, "build #{build_id}: state missing during #{operation}#{" of #{unit_id}" if unit_id}"
          end
          reply
        end

        # SCRIPT LOAD once per process, EVALSHA thereafter, EVAL if the server
        # lost the script (restart, SCRIPT FLUSH).
        def run_script(name, keys, argv)
          sha = (@shas[name] ||= redis.script(:load, SCRIPTS.fetch(name)))
          redis.evalsha(sha, keys: keys, argv: argv)
        rescue Redis::NoScriptError
          @shas.delete(name)
          redis.eval(SCRIPTS.fetch(name), keys: keys, argv: argv)
        end

        def read_group(worker_id, stream, block_ms)
          key = keyset.stream(stream)
          reply = redis.xreadgroup(Keys::CONSUMER_GROUP, worker_id, key, ">", count: 1, block: block_ms)
          entry = reply[key]&.first
          return nil unless entry

          [stream, entry[0], entry[1]]
        rescue Redis::CommandError => e
          raise CorruptBuild, "build #{build_id}: #{e.message}" if e.message.start_with?("NOGROUP")

          raise
        end
      end
    end
  end
end
