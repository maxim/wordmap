require 'wordmap/index_value'

class Wordmap
  module Builder
    module_function

    def build_vectors(hash)
      vectors = hash.first[0].is_a?(Array) ? hash.keys.transpose : [hash.keys]
      vectors.map!(&:uniq)
      vectors.map!(&:sort)
      vectors
    end

    # TODO: drop null bytes at the beginning (offset in meta)
    # TODO: drop null bytes at the end
    def write_data(path, vecs, cells_c, hash, spacer)
      File.open("#{path}/data", 'wb') do |file|
        cell_w = hash.values.max_by(&:bytesize).bytesize
        file.write("#{cell_w},#{cells_c}#{spacer}")

        key_iterator =
          vecs.size == 1 ? vecs[0].each : vecs[0].product(*vecs[1..-1]).to_enum

        key_iterator.with_index do |key, cell_i|
          value = hash[key].to_s
          yield(key, value, cell_i) unless value.empty?
          file.write(rjust_bytes(value, cell_w, spacer))
        end
      end
    end

    def write_vector(path, vector, spacer)
      cell_w = vector.max_by(&:bytesize).bytesize

      File.open(path, 'wb') do |file|
        file.write("#{cell_w},#{vector.size}#{spacer}")

        vector.each do |key|
          file.write(rjust_bytes(key.to_s, cell_w, spacer))
        end
      end
    end

    def rjust_bytes(string, bytesize, spacer)
      difference = bytesize - string.bytesize
      (spacer * difference) + string
    end
  end
end
