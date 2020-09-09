class Wordmap
  module FileAccess
    module_function

    def each_cell file, start = 0,
      meta:,
      count: Float::INFINITY,
      batch_size: meta[:batch_size],
      trace: nil

      unless block_given?
        return enum_for(__method__, file, start,
          meta: meta,
          count: count,
          batch_size: batch_size,
          trace: trace
        )
      end

      seen = 0

      loop do
        batch_size = count if (count < batch_size)
        cells = read_cells(file, start + seen, batch_size, meta, trace)
        cells.each do |cell|
          yield(cell)
        end

        seen += cells.size
        count -= cells.size
        break if count < 1
        break if cells.size < batch_size
      end
    end

    def read_cells(file, i, count, meta, trace)
      meta_offset, cell_size, cell_count =
        meta.values_at(:offset, :cell_size, :cell_count)

      return [] if i + 1 > meta[:cell_count]

      if i + count + 1 > meta[:cell_count]
        count = (meta[:cell_count] - i)
      end

      pos   = meta[:offset] + (i * meta[:cell_size])
      bytes = meta[:cell_size] * count

      if trace
        parts = file.path.split('.wmap', 2)
        subpath = (File.basename(parts[0]) + '.wmap') + parts[1]
        trace << [:read_cells, subpath, i, count, pos, bytes]
      end
      read_at(file, pos, bytes).unpack("a#{meta[:cell_size]}" * count)
    end

    def read_meta(file, spacer)
      meta_string = read_at(file, 0, 30).split(spacer, 2)[0]
      cell_size, cell_count = meta_string.split(',').map(&:to_i)
      {
        offset:     meta_string.bytesize + 1,
        cell_size:  cell_size,
        cell_count: cell_count,
        batch_size: [[10_000 / cell_size, 1].max, cell_count].min
      }
    end

    def read_at(file, pos, bytes)
      # puts "Seeking in #{file.path.split('.wmap', 2)[1][1..-1]} to #{pos}, " \
      #      "and reading #{bytes} bytes"
      file.sysseek(pos)
      file.sysread(bytes)
    end
  end
end
