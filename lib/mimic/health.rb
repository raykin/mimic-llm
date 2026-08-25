require_relative "ui"
require "time"
require_relative "agent/hermes"
require_relative "health/checks"

module Mimic
  module Health
    LOG_LINE_PAT = /\A(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ (WARNING|ERROR)/

    class << self
      # Count WARNING/ERROR lines in the Hermes logs within window.
      def count_recent_errors(minutes: 60)
        counts = { warn: 0, error: 0 }
        cutoff = Time.now - (minutes * 60)
        [Agent::Hermes::AGENT_LOG, Agent::Hermes::ERRORS_LOG].each { |logpath| tally_log(logpath, counts, cutoff) }
        counts
      end

      # Grab last N ERROR lines from errors.log.
      def recent_error_sample(n: 3)
        return [] unless Agent::Hermes::ERRORS_LOG.exist?

        lines = read_lines(Agent::Hermes::ERRORS_LOG) || []
        lines.select { |line| line.include?(" ERROR ") }.last(n)
      end

      # Verify the whole stack: what is installed, what is running, recent errors.
      def run(settings)
        checks = Checks.new(settings).to_a
        errs = count_recent_errors

        Ui.table(header: ["Component", "Status", "Detail"], rows: report_rows(checks, errs))
        print_error_sample if errs[:error].positive?

        checks.all? { |_, result| result.ok? } && errs[:error].zero?
      end

      private
      def tally_log(logpath, counts, cutoff)
        return unless logpath.exist?

        lines = read_lines(logpath)
        return if lines.nil?

        lines.reverse_each do |line|
          m = LOG_LINE_PAT.match(line)
          next unless m
          break if Time.strptime(m[1], "%Y-%m-%d %H:%M:%S") < cutoff

          m[2] == "WARNING" ? counts[:warn] += 1 : counts[:error] += 1
        end
      end

      # A log the engine wrote can hold a truncated multibyte character;
      # naming an external encoding on read transcodes nothing, so the bytes
      # have to be scrubbed after the fact. nil means the log could not be read
      # at all, which is not a reason to fail the whole check.
      def read_lines(path)
        path.binread.force_encoding(Encoding::UTF_8).scrub.lines(chomp: true)
      rescue SystemCallError
        nil
      end

      def report_rows(checks, errs)
        rows = checks.map do |name, result|
          [name, result.ok? ? Ui.green("OK") : Ui.red("FAIL"), result.message]
        end
        err_label = errs[:error].zero? ? "OK" : "#{errs[:error]} errors, #{errs[:warn]} warns"
        rows << ["Errors (60m)", errs[:error].zero? ? Ui.green("OK") : Ui.red("ISSUES"), err_label]
      end

      def print_error_sample
        puts "\n#{Ui.bold_red('Recent errors:')}"
        recent_error_sample.each do |line|
          short = line.length > 200 ? "#{line[0, 200]}..." : line
          puts "  #{short}"
        end
      end
    end
  end
end
