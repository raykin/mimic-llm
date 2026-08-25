require "tmpdir"
require "fileutils"

RSpec.shared_context "a model-keyed store fixture" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      (@dir / "store").mkpath
      FileUtils.touch(@dir / "store/model.gguf")
      (@dir / "alias.gguf").make_symlink(@dir / "store/model.gguf")
      example.run
    end
  end

  before { stub_const("Mimic::LlmConfig::LLM_CONFIG_DIR", @dir / ".llm") }

  def alias_path = (@dir / "alias.gguf").to_s
  def target_path = (@dir / "store/model.gguf").to_s
end

RSpec.shared_examples "a store keyed by the resolved model path" do
  it "keys by the symlink target, so either path recalls the same entry" do
    remember_entry(alias_path)

    expect(JSON.parse(store_path.read).keys).to eq([Pathname.new(target_path).realpath.to_s])
    expect(recall_entry(alias_path)).to eq(stored_value)
    expect(recall_entry(target_path)).to eq(stored_value)
  end

  it "recalls nothing instead of raising when the store is unreadable" do
    remember_entry(alias_path)
    store_path.chmod(0o000)

    expect(recall_entry(alias_path)).to be_nil
  end
end
