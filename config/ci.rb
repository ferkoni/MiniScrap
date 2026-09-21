# Run using bin/ci — the same checks the GitHub Actions workflow runs, locally.
# Offline: no Docker, curl-impersonate, or network needed (the :live specs are
# opt-in with LIVE=1 and are not part of CI).

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  step "Tests: RSpec", "bundle exec rspec"
end
