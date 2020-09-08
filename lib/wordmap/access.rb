require 'wordmap/file_access'
require 'wordmap/index_value'

class Wordmap
  module Access
    module_function

    def load_descriptors(paths, spacer)
      paths.reduce({}) { |hash, path|
        file = File.open(path, 'rb')
        meta = FileAccess.read_meta(file, spacer)
        hash.merge(File.basename(path) => { file: file, meta: meta })
      }
    end

    def each_by_query descriptors, indexes, query, ltrim_regex, trace
      unless block_given?
        return enum_for(
          __method__, descriptors, indexes, query, ltrim_regex, trace
        )
      end

      index_values =
        if query.none? { |clause| clause.is_a?(Array) }
          [
            clause_to_index_value(
              query, descriptors, indexes, ltrim_regex, trace
            )
          ]
        else
          # Proactively intersect all clauses of the same type to save on reads.
          map_normalized_clauses(query) { |clause|
            clause_to_index_value \
              clause, descriptors, indexes, ltrim_regex, trace
          }
        end

      IndexValue
        .each_seq_value(*index_values)
        .lazy
        .slice_when { |a, b| b > a.succ }
        .each { |seq|
          subtrace = nil
          if trace
            subtrace = []
            trace << [:each_by_query, "#{seq.first}-#{seq.last}", subtrace]
          end

          FileAccess
            .each_cell(descriptors['data'][:file], seq[0],
              count: seq.size,
              meta: descriptors['data'][:meta],
              trace: subtrace
            ) { |cell|
              value = extract_value(cell, ltrim_regex)
              yield(value) unless value.empty?
            }
        }
    end

    def each_by_key(descriptors, key, ltrim_regex, trace)
      unless block_given?
        return enum_for(__method__, descriptors, key, ltrim_regex, trace)
      end

      index_value = index_value_by_key(descriptors, key, ltrim_regex, trace)
      return [].to_enum if index_value == ''
      seq = IndexValue.each_seq_value(index_value).to_a

      subtrace = nil

      if trace
        subtrace = []
        trace << [:each_by_key, "#{seq.first}-#{seq.last}", subtrace]
      end

      FileAccess.each_cell(descriptors['data'][:file], seq[0],
        count: seq.size,
        meta: descriptors['data'][:meta],
        trace: subtrace
      ) { |cell|
        value = extract_value(cell, ltrim_regex)
        yield(value) unless value.empty?
      }
    end

    def each(descriptors, indexes, vec_or_index, ltrim_regex, trace)
      unless block_given?
        return enum_for(
          __method__,
          descriptors,
          indexes,
          vec_or_index,
          ltrim_regex,
          trace
        )
      end

      case vec_or_index
      when NilClass, Integer
        descriptor = vec_or_index.nil? ? 'data' : "vec#{vec_or_index}"
        file, meta = descriptors[descriptor].values_at(:file, :meta)

        subtrace = nil

        if trace
          subtrace = []
          trace << [:each, descriptor, subtrace]
        end

        FileAccess.each_cell(file, meta: meta, trace: subtrace) { |cell|
          value = extract_value(cell, ltrim_regex)
          yield(value) unless value.empty?
        }
      when Symbol
        raise "Unknown index: #{vec_or_index}" unless indexes.key?(vec_or_index)

        subtrace = nil

        if trace
          subtrace = []
          trace << [:each, vec_or_index, subtrace]
        end

        indexes[vec_or_index].each(0, trace: subtrace) { |cell| yield(cell) }
        subtrace.replace(subtrace.flat_map { |v| v[2] }) if trace
      else
        raise 'Invalid value passed into each'
      end
    end

    def index_value_by_key(descriptors, key, ltrim_regex, trace)
      key = Array(key)
      cell_count = descriptors['data'][:meta][:cell_count]

      cell_c, cell_i =
        0.upto(key.size - 1).reduce([cell_count, 0]) { |(cc, ci), vi|
          vec_desc = descriptors["vec#{vi}"]
          return '' unless vec_desc
          vmeta = vec_desc[:meta]
          vfile = vec_desc[:file]
          vec_index = bsearch_vec(vfile, key[vi], vmeta, ltrim_regex, trace)
          return '' unless vec_index
          page_size = cc / vmeta[:cell_count]
          [page_size, ci + (page_size * vec_index)]
        }

      cell_c > 1 ? "#{cell_i}+#{cell_c - 1}"  : "#{cell_i}"
    end

    def bsearch_vec(file, value, meta, ltrim_regex, trace)
      subtrace = nil

      if trace
        subtrace = []
        trace << [__method__, value, subtrace]
      end

      (0..(meta[:cell_count] - 1)).bsearch { |i|
        cell = FileAccess.read_cells(file, i, 1, meta, subtrace)[0]
        value <=> extract_value(cell, ltrim_regex)
      }
    end

    def clause_to_index_value(clause, descriptors, indexes, ltrim_regex, trace)
      name, *keys = clause

      case name
      when Symbol
        raise "Unknown index: #{name}" unless indexes.key?(name)
        keys.map { |key| indexes[name][key, trace: trace].first || '' }
      else
        # For vector lookup, if keys are sorted, then positions are guaranteed
        # to be sorted too, which means we can get away with getting locations
        # lazily here.
        vec_iterator(descriptors, Array(clause), ltrim_regex, trace)
      end
    end

    def vec_iterator(descriptors, keys, ltrim_regex, trace = nil)
      unless block_given?
        return enum_for(__method__, descriptors, keys, ltrim_regex, trace)
      end

      keys.sort.each do |key|
        value = index_value_by_key(descriptors, key, ltrim_regex, trace)
        next if value.nil? || value == ''
        yield(value.to_i)
      end
    end

    def map_normalized_clauses(query)
      query
        .reduce({}) { |normalized, clause|
          normalized.merge(
            clause[0].is_a?(Symbol) ?
              { clause[0] => clause[1..-1] } :
              { '_keys' => clause }
          ) { |_, oldv, newv| oldv & newv }
        }
        .map { |name, keys|
          name == '_keys' ? yield(keys) : yield([name, *keys])
        }
    end

    def extract_value(cell, regex)
      cell.sub(regex, '').force_encoding('utf-8')
    end
  end
end
