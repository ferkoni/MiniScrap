require "open3"

module Scraper
  # Runs an external command (argv, never a shell string) and captures its
  # output, killing it if it outlives `timeout` so a hung child can never hang
  # the request. The shell-out seam for CurlImpersonateFetcher.
  module Subprocess
    Result = Data.define(:stdout, :stderr, :exitstatus) do
      def success?
        exitstatus == 0
      end
    end

    # The process was killed for exceeding its timeout. Plumbing, not a flow
    # error: callers translate it into their own failure (e.g. FetchFailed).
    class TimedOut < StandardError; end

    def self.run(argv, timeout:)
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait|
        stdin.close
        # Drain both pipes concurrently so a chatty child can't block on a full one.
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }

        unless wait.join(timeout)
          Process.kill("KILL", wait.pid)
          [wait, out, err].each(&:join)
          raise TimedOut, "#{File.basename(argv.first)} killed after #{timeout}s"
        end

        Result.new(stdout: out.value, stderr: err.value, exitstatus: wait.value.exitstatus)
      end
    end
  end
end
