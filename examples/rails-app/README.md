# rspec-hopper Rails example

The smallest Rails application that exercises what the gem's own fixtures cannot:
ActiveRecord connections across `--boot shared` forks, one SQLite database per worker
process chosen by `TEST_ENV_NUMBER`, transactional tests, `before(:all)` records that
outlive the transaction, and a request spec through ActionDispatch.

`spec/support/hopper.rb` is the README's shared-boot recipe verbatim, and
`spec/support/database_guard.rb` is the recommended `before(:suite)` guard.

```sh
cd examples/rails-app
bundle install
bundle exec rspec                                  # plain RSpec, one process
bundle exec rspec-hopper work --build b1 --worker n1 --redis redis://127.0.0.1:6399/0 \
  --processes 3 --boot shared --report-on-exit --max-requeues 1 --requeue-tolerance 1
```

`spec/integration/rails_example_spec.rb` in the gem's own suite drives this app with
three shared-boot children in both unit modes and is skipped unless this directory's
bundle is installed. CircleCI runs it as the `rails-example` job.
