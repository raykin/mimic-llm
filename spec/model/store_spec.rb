require_relative "../../lib/mimic"
require_relative "../support/model_keyed_store"

RSpec.describe Mimic::Model::Store do
  include_context "a model-keyed store fixture"

  subject(:store) { described_class.new(store_path) }

  def store_path = @dir / ".llm/model-store.json"
  def stored_value = { "context_length" => 4096, "cache_type" => "q8_0" }
  def remember_entry(path) = store.write(path, stored_value)
  def recall_entry(path) = store.fetch(path)

  it_behaves_like "a store keyed by the resolved model path"

  it "fetches nil for a model it has never seen" do
    expect(store.fetch(target_path)).to be_nil
  end

  it "yields nil instead of raising on a corrupt file" do
    store_path.dirname.mkpath
    store_path.write("not json")

    expect(store.fetch(target_path)).to be_nil
  end

  describe "#delete" do
    it "removes an existing entry" do
      store.write(target_path, stored_value)
      store.delete(target_path)

      expect(store.fetch(target_path)).to be_nil
      expect(JSON.parse(store_path.read)).to eq({})
    end

    it "does not create the file for a model that was never stored" do
      store.delete(target_path)

      expect(store_path).not_to exist
    end
  end
end
