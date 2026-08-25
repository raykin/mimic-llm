require_relative "../ui"
require "pathname"
require_relative "../util/fmt"
require_relative "../llm_config"
require_relative "../model"
require_relative "../paths"
require_relative "../model/footprint"
require_relative "../model/upstream"
require_relative "../util/hf"

module Mimic
  # The `llm models` board: every GGUF under the configured search paths,
  # with the per-model facts that decide whether it will actually run.
  module LlmCli
    class ModelsTable
      HEADER = ["", "Alias", "Quant", "Size", "MoE", "MTP", "Vision", "n_cpu_moe", "Template", "Last Ctx", "Path"].freeze
      ALIAS_WIDTH = 44
      PATH_WIDTH = 20

      def initialize(config, scan, client: nil)
        @config = config
        @scan = scan
        @client = client
      end

      def render
        rows = @scan.map { |model| row(model) }
        return no_models if rows.empty?

        Ui.table(header: header, rows: rows)
        print_upstream_legend if @client
        puts "\nSwitch with `llm setup` -- active model is marked ●"
        print_search_paths
      end

      private

      def header = @client ? HEADER + ["Upstream"] : HEADER

      def row(model)
        path = model.path
        real = model.real
        base_alias = model.model_alias
        remembered = Model.new(real)
        cells = [
          real == active_real ? Ui.green("●") : "",
          truncate(base_alias, ALIAS_WIDTH),
          path.basename(".*").to_s.delete_prefix(base_alias).sub(/\A-/, ""),
          Util::Fmt.human_size(real.size),
          moe_mark(real),
          model.supports_mtp? ? Ui.green("✓") : "",
          model.vision? ? Ui.green("✓") : "",
          remembered.memory.n_cpu_moe&.to_s || "",
          template_for(base_alias).file? ? "✓" : "",
          last_ctx(remembered),
          parent_label(path),
        ]
        @client ? cells + [upstream_mark(model)] : cells
      end

      def print_upstream_legend
        puts "\nUpstream compares file size against the repo the GGUF was published from."
        puts "  #{Ui.gray('?')}  no source repo -- the header names none and the path is not LM Studio's, or huggingface.co was unreachable"
        puts "  #{Ui.yellow('gone')}  the repo no longer publishes a file by that name"
      end

      def upstream_mark(model)
        upstream = Model::Upstream.new(model, client: @client)
        case upstream.verdict
        when :current then Ui.green("current")
        when :stale then Ui.red(["stale", upstream.updated_at].compact.join(" "))
        when :gone then Ui.yellow("gone")
        else Ui.gray("?")
        end
      end

      def active_real
        @active_real ||= begin
          active = Pathname.new(@config.model.path).expand_path
          active.exist? ? active.realpath : active
        end
      end

      def moe_mark(real)
        moe = Model::Header.new(real).moe?
        return "" if moe.nil?

        moe ? Ui.green("✓") : Ui.red("✗")
      end

      def template_for(base_alias) = Mimic::Paths::CHAT_TEMPLATES_DIR / "#{base_alias}.jinja"

      def last_ctx(model)
        recalled = model.memory.last_ctx&.first
        recalled.nil? ? "" : Util::Fmt.commas(recalled)
      end

      def parent_label(path)
        label = path.dirname.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
        label.length > PATH_WIDTH ? "…#{label[-(PATH_WIDTH - 1)..]}" : label
      end

      def truncate(text, width) = text.length > width ? "#{text[0, width - 1]}…" : text

      def no_models
        puts "No .gguf files found in #{@config.search_paths.to_a.join(', ')}"
        print_search_paths
      end

      def print_search_paths
        puts "\nSearched:"
        @config.search_paths.each do |directory|
          mark = directory.directory? ? Ui.green("✓") : Ui.red("✗")
          puts "  #{mark} #{directory}"
        end
      end
    end
  end
end
