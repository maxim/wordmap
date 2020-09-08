require 'set'

class Wordmap
  module IndexValue
    module_function

    def pack(numbers)
      last = 0

      numbers
        .slice_when { |a, b| b > a.succ }
        .map { |h, *t| [h - last, t.size].tap { last = t.last || h } }
        .map { |v, r| r.zero? ? v.to_s : "#{v}+#{r}" }
        .join(',')
    end

    def each_seq_value(*arrays_of_seqs)
      return enum_for(__method__, *arrays_of_seqs) unless block_given?

      iters = arrays_of_seqs.map { |union_array|
        case union_array
        when Enumerator; [union_array]
        when String; [iterator(union_array)]
        else; union_array.map { |seq| iterator(seq) }
        end
      }

      combine(*iters) { |value| yield(value) }
    end

    def combine(*arrays_of_iters)
      return enum_for(__method__, *arrays_of_iters) unless block_given?
      intersect(*arrays_of_iters.map { |array| uniq_union(*array) }) do |value|
        yield(value)
      end
    end

    def intersect(*iters)
      return enum_for(__method__, *iters) unless block_given?

      last = nil
      given = 0
      wrap_up = false

      union(*iters, control_messages: true) do |value|
        if value == :__iter_exhausted
          wrap_up = true
          next
        end

        break if wrap_up && last != value

        last == value ? (given += 1) : (given = 1)
        yield(value) if given == iters.size
        last = value
      end
    end

    def uniq_union(*iters)
      return enum_for(__method__, *iters) unless block_given?

      last = nil

      union(*iters) do |value|
        yield(value) unless value == last
        last = value
      end
    end

    def union(*iters, control_messages: false)
      unless block_given?
        return enum_for(__method__, *iters, control_messages: control_messages)
      end

      iters = iters.map { |iter| [iter.rewind, true] }

      loop do
        iter_exhausted = false

        next_iter =
          iters.select { |iter| iter[1] }.min_by do |iter|
            iter[0].peek
          rescue StopIteration
            iter[1] = false
            iter_exhausted = true
            next(Float::INFINITY)
          end

        all_iters_exhausted = iters.none? { |iter| iter[1] }

        if control_messages && iter_exhausted && !all_iters_exhausted
          yield(:__iter_exhausted)
        end

        value = next_iter[0].next
        yield(value)
        break if all_iters_exhausted
      end
    end

    def iterator(value)
      return enum_for(__method__, value) unless block_given?

      last = 0

      value.enum_for(:scan, /[\d\+]+/).each do |seq|
        n, extra = seq.split('+').map(&:to_i)
        v1 = last + n

        if extra
          v2 = (v1 + extra)
          (v1..v2).each { |i| yield(i) }
          last = v2
        else
          yield(v1)
          last = v1
        end
      end
    end
  end
end
