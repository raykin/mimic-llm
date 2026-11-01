require "pathname"
require_relative "../paths"
require_relative "../model/header"
require_relative "../model"
require_relative "../util/probes"

module Mimic
  # A model's embedded Jinja chat template, and the override mimic hands the
  # server when that template would throw on real agent traffic.
  #
  # The Qwen-family templates ship `raise_exception` guards that llama.cpp's
  # minja evaluates at render time: a request whose message list trips one
  # comes back as a 500 rather than a completion. Claude Code trips
  # `System message must be at the beginning` because llama.cpp's
  # /v1/messages bridge emits system content the guard does not expect.
  #
  # Each rule replaces one guard with what the template should have rendered.
  # `requires` names the constructs the replacement leans on -- a template
  # that phrases its loop differently gets that guard left alone rather than
  # rewritten wrong, and the hand-written override in CHAT_TEMPLATES_DIR
  # stays the answer for it.
  module Engine
    class ChatTemplate
      METADATA_KEY = "tokenizer.chat_template".freeze
      RAISE_CALL = /\{\{-?\s*raise_exception\(\s*(['"])(.*?)\1\s*\)\s*-?\}\}/m

      NOOP = "{{- '' }}".freeze

      EFFORT_DEFAULT = /reasoning_effort\s*\|\s*default\(\s*['"]([\w-]+)['"]/
      EFFORT_FALLBACK = /set\s+reasoning_effort\s*=\s*['"]([\w-]+)['"]/
      EFFORT_CHOICES = /reasoning_effort\s+not\s+in\s+[(\[]([^)\]]*)[)\]]/
      EFFORT_COMPARE = /reasoning_effort\s*==\s*['"]([\w-]+)['"]/
      QUOTED = /['"]([\w-]+)['"]/

      # gpt-oss's harmony template prints reasoning_effort without listing
      # the values; these are the ones the format defines.
      HARMONY_CHANNEL = "<|channel|>".freeze
      HARMONY_EFFORTS = %w[low medium high].freeze

      # llama.cpp's --reasoning auto renders the template and asks its format
      # handler; these are the markers those handlers turn thinking on for.
      THINKING_MARKERS = ["enable_thinking", "<think>", "[THINK]", HARMONY_CHANNEL].freeze

      Rule = Struct.new(:match, :replacement, :requires, keyword_init: true)

      RULES = [
        Rule.new(
          match: /system message must be at the beginning/i,
          replacement: %q({{- '<|im_start|>system\n' + content + '<|im_end|>' + '\n' }}),
          requires: ["<|im_start|>system", "set content = render_content("],
        ),
        Rule.new(
          match: /unexpected message role/i,
          replacement: %q({{- '<|im_start|>user\n' + content + '<|im_end|>' + '\n' }}),
          requires: ["<|im_start|>system", "set content = render_content("],
        ),
        Rule.new(
          match: /unexpected item type in content/i,
          replacement: "{{- item.text if item.text is defined else '' }}",
          requires: ["for item in content"],
        ),
        Rule.new(
          match: /unexpected content type/i,
          replacement: "{{- content | string }}",
          requires: [],
        ),
        Rule.new(
          match: /system message cannot contain|no messages provided|no user query found/i,
          replacement: NOOP,
          requires: [],
        ),
      ].freeze

      # Renders the message shapes real agents send through the server's own
      # /apply-template, which runs the same minja pass as a completion. A 500
      # here is the template throwing -- the exact failure a request would hit,
      # measured instead of predicted. Both engines expose the endpoint.
      class Probe
        SYSTEM = { role: "system", content: "You are a coding agent." }.freeze
        USER = { role: "user", content: "list the files" }.freeze

        FIXTURES = {
          "a system message after the first turn" =>
            [SYSTEM, USER, { role: "system", content: "<system-reminder>stay on task</system-reminder>" }],
          "an assistant tool call and its response" =>
            [SYSTEM, USER,
             { role: "assistant", content: "",
               tool_calls: [{ type: "function",
                              function: { name: "Read", arguments: { path: "/tmp/x" } } }] },
             { role: "tool", content: "file body" }],
          "content sent as typed blocks" =>
            [SYSTEM, { role: "user", content: [{ type: "text", text: "and now?" }] }],
        }.freeze

        def initialize(base_url, model_alias:)
          @url = "#{base_url}/apply-template"
          @model_alias = model_alias
        end

        def failures
          FIXTURES.filter_map do |label, messages|
            res = Util::Probes.post(@url, { model: @model_alias, messages: messages })
            label if res && res.code.to_i >= 500
          end
        end
      end

      def initialize(model_path, model_alias:)
        @model_path = model_path.to_s
        @model_alias = model_alias.to_s
      end

      def source
        return @source if defined?(@source)

        # full: the template is written after the vocab arrays, and the
        # default read stops at the first of them.
        @source = Model::Header.new(@model_path).metadata(full: true)[METADATA_KEY]
      rescue StandardError
        @source = nil
      end

      def guarded? = source.to_s.include?("raise_exception")

      # The reasoning_effort values the served template accepts, in its own
      # order: an override when one exists, the GGUF's template otherwise.
      # Fewer than two means there is nothing to choose between.
      def effort_levels
        text = served_source.to_s
        listed = text[EFFORT_CHOICES, 1]
        levels = listed ? listed.scan(QUOTED).flatten : text.scan(EFFORT_COMPARE).flatten
        levels = HARMONY_EFFORTS if levels.empty? && harmony?(text)
        levels = (levels + [default_effort].compact).uniq
        levels.size < 2 ? [] : levels
      end

      def default_effort
        text = served_source.to_s
        text[EFFORT_DEFAULT, 1] || text[EFFORT_FALLBACK, 1]
      end

      def thinks?
        text = served_source.to_s
        THINKING_MARKERS.any? { |marker| text.include?(marker) }
      end

      # Hand-written first: a file the user wrote is a decision, and mimic's
      # rules do not get to overrule it.
      def override_path
        [hand_written, generated].find(&:file?)
      end

      def install
        return nil if hand_written.file?

        text = sanitized
        return nil if text.nil?

        generated.dirname.mkpath
        generated.write(text.end_with?("\n") ? text : "#{text}\n")
        generated
      end

      private

      # The rewritten template, or nil when no guard in it has a rule.
      #
      # Per guard, not per template: a guard mimic has no rule for is left
      # standing exactly as the model shipped it, so the shapes that trip it
      # keep failing the way they already do. Refusing the whole rewrite over
      # one such guard is what would change behaviour -- it drops repairs that
      # are correct and leaves a template that 500s on ordinary agent traffic.
      def sanitized
        return nil unless guarded?

        rewrote = false
        rewritten = source.gsub(RAISE_CALL) do
          whole = Regexp.last_match(0)
          rule = rule_for(Regexp.last_match(2))
          next whole if rule.nil?

          rewrote = true
          rule.replacement
        end
        rewrote ? rewritten : nil
      end

      def hand_written = Paths::CHAT_TEMPLATES_DIR / "#{@model_alias}.jinja"
      def generated = Paths::GENERATED_TEMPLATES_DIR / "#{@model_alias}.jinja"

      def served_source
        override = override_path
        override ? override.read : source
      end

      def harmony?(text) = text.include?(HARMONY_CHANNEL) && text.include?("reasoning_effort")

      def rule_for(message)
        rule = RULES.find { |r| r.match.match?(message) }
        return nil if rule.nil?
        return nil unless rule.requires.all? { |needle| source.include?(needle) }

        rule
      end
    end
  end
end
