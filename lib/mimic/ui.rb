require "cli/ui"

module Mimic
  # The only place that knows cli-ui exists. Everything else asks for a
  # Ui::Prompt or calls Ui.banner/panel/table, so swapping the terminal
  # library again is one file rather than every wizard.
  module Ui
    COLORS = %i[green red yellow cyan gray bold].freeze

    class << self
      def fmt(text) = CLI::UI.fmt(text)

      COLORS.each do |color|
        define_method(color) { |text| CLI::UI.fmt("{{#{color}:#{text}}}") }
      end

      def bold_cyan(text) = CLI::UI.fmt("{{bold:{{cyan:#{text}}}}}")
      def bold_red(text) = CLI::UI.fmt("{{bold:{{red:#{text}}}}}")

      def banner(title)
        puts CLI::UI.fmt("{{bold:#{title}}}")
      end

      def panel(body, title: nil)
        CLI::UI::Frame.open(title.to_s, color: :cyan) { puts body }
      end

      # Not CLI::UI::Table: both of its entry points render through
      # CLI::UI.puts, which hard-wraps at the terminal width and folds a wide
      # model board into unreadable fragments. Padding is measured with
      # printing_width so colour escapes do not count toward column widths.
      def table(header:, rows:)
        all = [header.map { |cell| bold(cell) }, *rows].map { |row| row.map(&:to_s) }
        widths = all.transpose.map { |col| col.map { |cell| CLI::UI::ANSI.printing_width(cell) }.max }
        all.each do |row|
          padded = row.each_with_index.map { |cell, i| cell + (" " * (widths[i] - CLI::UI::ANSI.printing_width(cell))) }
          puts padded.join("  ").rstrip
        end
      end
    end

    # tty-prompt's shape, backed by cli-ui: choices may be an Array of
    # labels, a Hash of label => value, or an Array of {name:, value:}, and
    # the answer is always the value rather than the label.
    class Prompt
      def select(question, choices, default: nil)
        pairs = normalize(choices)
        labels = pairs.map(&:first)
        picked = CLI::UI::Prompt.ask(question, options: labels, default: default_label(default, labels))
        pairs.to_h.fetch(picked)
      end

      def ask(question, default: nil, convert: nil)
        answer = CLI::UI::Prompt.ask(question, default: default&.to_s, allow_empty: false)
        convert == :int ? Integer(answer) : answer
      end

      def yes?(question, default: true)
        CLI::UI::Prompt.confirm(question, default: default)
      end

      private

      def normalize(choices)
        case choices
        when Hash then choices.to_a
        else choices.map { |choice| choice.is_a?(Hash) ? [choice.fetch(:name), choice.fetch(:value)] : [choice, choice] }
        end
      end

      # tty-prompt took either a label or a 1-based index; cli-ui only takes
      # a label, and rejects one that is not among the options.
      def default_label(default, labels)
        label = default.is_a?(Integer) ? labels[default - 1] : default
        labels.include?(label) ? label : nil
      end
    end
  end
end
