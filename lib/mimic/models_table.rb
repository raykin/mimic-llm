require "pathname"
require "tty-table"
require_relative "fmt"
require_relative "llm_config"
require_relative "paths"
require_relative "vram"
require_relative "services/ik_llama"

module Mimic
  # The `llm models` board: every GGUF under the configured search paths,
  # with the per-model facts that decide whether it will actually run.
  class ModelsTable
    HEADER = ["", "Alias", "Quant", "Size", "MoE", "n_cpu_moe", "Template", "Last Ctx", "Path"].freeze
    ALIAS_WIDTH = 44
    PATH_WIDTH = 20

    def initialize(config, scan, pastel:)
      @config = config
      @scan = scan
      @pastel = pastel
    end

    def render
      rows = @scan.map { |path, _scan_dir| row(path) }
      return no_models if rows.empty?

      puts TTY::Table.new(header: HEADER, rows: rows).render(:unicode, multiline: false)
      puts "\nSwitch with `llm setup` -- active model is marked ●"
      print_search_paths
    end

    private

    def row(path)
      real = path.realpath
      base_alias = LlmConfig::Settings.alias_for(path.to_s)
      [
        real == active_real ? @pastel.green("●") : "",
        truncate(base_alias, ALIAS_WIDTH),
        path.basename(".*").to_s.delete_prefix(base_alias).sub(/\A-/, ""),
        Fmt.human_size(real.size),
        moe_mark(real),
        moe_cache[real.to_s]&.to_s || moe_cache[path.to_s]&.to_s || "",
        template_for(base_alias).file? ? "✓" : "",
        last_ctx(path),
        parent_label(path),
      ]
    end

    def active_real
      @active_real ||= begin
        active = Pathname.new(@config.model_path).expand_path
        active.exist? ? active.realpath : active
      end
    end

    def moe_cache = @moe_cache ||= Services::IkLlama.load_cache

    def moe_mark(real)
      moe = Vram.moe?(real.to_s)
      return "" if moe.nil?

      moe ? @pastel.green("✓") : @pastel.red("✗")
    end

    def template_for(base_alias) = Paths::CHAT_TEMPLATES_DIR / "#{base_alias}.jinja"

    def last_ctx(path)
      recalled = LlmConfig.recall_ctx(path.to_s)&.first
      recalled.nil? ? "" : Fmt.commas(recalled)
    end

    def parent_label(path)
      label = path.dirname.to_s.sub(/\A#{Regexp.escape(Dir.home)}/, "~")
      label.length > PATH_WIDTH ? "…#{label[-(PATH_WIDTH - 1)..]}" : label
    end

    def truncate(text, width) = text.length > width ? "#{text[0, width - 1]}…" : text

    def no_models
      puts "No .gguf files found in #{@config.search_paths.join(', ')}"
      print_search_paths
    end

    def print_search_paths
      puts "\nSearched:"
      @config.search_paths.each do |directory|
        mark = directory.directory? ? @pastel.green("✓") : @pastel.red("✗")
        puts "  #{mark} #{directory}"
      end
    end
  end
end
