require_relative "../../lib/mimic"
require_relative "../support/gguf_writer"
require "tmpdir"

RSpec.describe Mimic::Engine::ChatTemplate do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      @templates = @dir / "chat-templates"
      example.run
    end
  end

  before do
    stub_const("Mimic::Paths::CHAT_TEMPLATES_DIR", @templates)
    stub_const("Mimic::Paths::GENERATED_TEMPLATES_DIR", @templates / "generated")
  end

  QWEN_PREAMBLE = <<~JINJA.freeze
    {%- macro render_content(content, do_vision_count, is_system_content=false) %}
        {%- if content is string %}
            {{- content }}
        {%- elif content is iterable and content is not mapping %}
            {%- for item in content %}
                {%- if 'text' in item %}
                    {{- item.text }}
                {%- else %}
                    {{- raise_exception('Unexpected item type in content.') }}
                {%- endif %}
            {%- endfor %}
        {%- else %}
            {{- raise_exception('Unexpected content type.') }}
        {%- endif %}
    {%- endmacro %}
    {%- for message in messages %}
        {%- set content = render_content(message.content, true)|trim %}
        {%- if message.role == "system" %}
            {%- if not loop.first %}
                {{- raise_exception('System message must be at the beginning.') }}
            {%- endif %}
        {%- elif message.role == "user" %}
            {{- '<|im_start|>system\\n' + content + '<|im_end|>' + '\\n' }}
        {%- else %}
            {{- raise_exception('Unexpected message role.') }}
        {%- endif %}
    {%- endfor %}
  JINJA

  def model_with(template)
    path = @dir / "model.gguf"
    keys = { "general.architecture" => "qwen3" }
    keys["tokenizer.chat_template"] = template unless template.nil?
    GgufWriter.write(path, keys)
    path
  end

  def build(template, model_alias: "TestModel")
    described_class.new(model_with(template), model_alias: model_alias)
  end

  describe "#guarded?" do
    it "is false for a template with no raise_exception" do
      expect(build("{%- for m in messages %}{{ m.content }}{%- endfor %}").guarded?).to be(false)
    end

    it "is false when the GGUF carries no embedded template" do
      expect(build(nil).guarded?).to be(false)
    end

    it "is true when the template can throw" do
      expect(build(QWEN_PREAMBLE).guarded?).to be(true)
    end

    # Real GGUFs carry the template *after* the vocab, and the default
    # metadata read stops at the first vocab-sized string array.
    it "reads a template that sits behind the vocab arrays" do
      path = @dir / "vocab.gguf"
      GgufWriter.write(path, {
                         "general.architecture" => "qwen3",
                         "qwen3.block_count" => 48,
                         "tokenizer.ggml.tokens" => GgufWriter::StringArray.new(Array.new(5000) { |i| "t#{i}" }),
                         "tokenizer.chat_template" => QWEN_PREAMBLE,
                       })

      expect(described_class.new(path, model_alias: "Vocab").guarded?).to be(true)
    end
  end

  describe "#install" do
    it "writes the sanitized template under the generated directory" do
      written = build(QWEN_PREAMBLE).install

      expect(written).to eq(@templates / "generated" / "TestModel.jinja")
      expect(written.read).not_to include("raise_exception")
    end

    it "does nothing when the template cannot throw" do
      expect(build("{{ messages[0].content }}").install).to be_nil
      expect(@templates / "generated").not_to exist
    end

    it "does not generate over a hand-written override" do
      (@templates).mkpath
      (@templates / "TestModel.jinja").write("hand written\n")

      expect(build(QWEN_PREAMBLE).install).to be_nil
      expect(@templates / "generated").not_to exist
    end

    it "refreshes a stale generated file" do
      generated = @templates / "generated" / "TestModel.jinja"
      generated.dirname.mkpath
      generated.write("old\n")

      build(QWEN_PREAMBLE).install
      expect(generated.read).to include("<|im_start|>user")
    end
  end

  describe "#install rewriting the guards" do
    def installed(template) = build(template).install&.read

    it "renders a late system message as its own turn instead of throwing" do
      expect(installed(QWEN_PREAMBLE))
        .to include("{%- if not loop.first %}\n            {{- '<|im_start|>system\\n' + content + '<|im_end|>' + '\\n' }}")
    end

    it "renders an unrecognised role as a user turn instead of dropping it" do
      expect(installed(QWEN_PREAMBLE)).to include("{{- '<|im_start|>user\\n' + content + '<|im_end|>' + '\\n' }}")
    end

    it "falls back to item text for an unrecognised content item" do
      expect(installed(QWEN_PREAMBLE)).to include("{{- item.text if item.text is defined else '' }}")
    end

    # Qwen3.8-27B ships ten guards; three are about tool-call argument shapes
    # mimic has no opinion on. All-or-nothing threw away the system-message
    # repair over those three and left the server 500ing on every Claude Code
    # <system-reminder>.
    it "repairs the guards it knows and leaves the rest standing" do
      template = "#{QWEN_PREAMBLE}{%- if bad %}{{- raise_exception('Tool call is missing a function name.') }}{%- endif %}"

      sanitized = installed(template)

      expect(sanitized).to include("{{- '<|im_start|>system\\n' + content + '<|im_end|>' + '\\n' }}")
      expect(sanitized).to include("raise_exception('Tool call is missing a function name.')")
    end

    it "refuses a guard message no rule covers" do
      template = "{%- if x %}{{- raise_exception('Some brand new guard.') }}{%- endif %}"
      expect(installed(template)).to be_nil
    end

    it "refuses a rendering rule when the template lacks the tokens it would emit" do
      template = "{%- for m in messages %}{{- raise_exception('System message must be at the beginning.') }}{%- endfor %}"
      expect(installed(template)).to be_nil
    end
  end

  describe "#override_path" do
    it "prefers a hand-written override over a generated one" do
      @templates.mkpath
      (@templates / "TestModel.jinja").write("hand written\n")
      (@templates / "generated").mkpath
      (@templates / "generated" / "TestModel.jinja").write("generated\n")

      expect(build(QWEN_PREAMBLE).override_path).to eq(@templates / "TestModel.jinja")
    end

    it "falls back to the generated override" do
      generated = @templates / "generated" / "TestModel.jinja"
      generated.dirname.mkpath
      generated.write("generated\n")

      expect(build(QWEN_PREAMBLE).override_path).to eq(generated)
    end

    it "is nil when neither exists" do
      expect(build(QWEN_PREAMBLE).override_path).to be_nil
    end
  end
end
