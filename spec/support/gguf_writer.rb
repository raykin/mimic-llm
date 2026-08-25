# Minimal GGUF v3 writer covering only what Model::Gguf#metadata parses:
# magic, version, tensor count, then N key/value pairs. Types used here are
# STRING (8) and UINT32 (4), matching what the real header carries for the
# keys Model::Header and Model::Footprint care about.
module GgufWriter
  UINT32 = 4
  FLOAT32 = 6
  STRING = 8
  ARRAY = 9

  # A string array value: `GgufWriter.write(path, "tokenizer.ggml.tokens" => StringArray.new(%w[a b]))`
  StringArray = Struct.new(:entries)

  module_function

  # `tensors` is [[name, byte_size], ...] or [[name, byte_size, ggml_type,
  # element_count], ...]; offsets are assigned sequentially
  # and that many bytes of data are appended, so a reader can recover each
  # size from the gap to the next offset (and the last from the file size).
  def write(path, kv, tensors: [])
    File.open(path, "wb") do |f|
      f.write("GGUF")
      f.write([3].pack("L<"))               # version
      f.write([tensors.size].pack("Q<"))    # tensor count
      f.write([kv.size].pack("Q<"))         # kv count
      kv.each do |key, value|
        write_string(f, key)
        if value.is_a?(StringArray)
          f.write([ARRAY].pack("L<"))
          f.write([STRING].pack("L<"))
          f.write([value.entries.size].pack("Q<"))
          value.entries.each { |e| write_string(f, e) }
        elsif value.is_a?(String)
          f.write([STRING].pack("L<"))
          write_string(f, value)
        elsif value.is_a?(Float)
          f.write([FLOAT32].pack("L<"))
          f.write([value].pack("e"))
        else
          f.write([UINT32].pack("L<"))
          f.write([value].pack("L<"))
        end
      end
      write_tensor_info(f, tensors)
      tensors.each { |_name, size, _type, _elems| f.write("\0" * size) }
    end
  end

  def write_tensor_info(f, tensors)
    offset = 0
    tensors.each do |name, size, type, elems|
      write_string(f, name)
      f.write([1].pack("L<"))               # n_dims
      f.write([elems || 1].pack("Q<"))      # dims[0]
      f.write([type || 0].pack("L<"))       # ggml type
      f.write([offset].pack("Q<"))
      offset += size
    end
  end

  def write_string(f, s)
    f.write([s.bytesize].pack("Q<"))
    f.write(s)
  end
end
