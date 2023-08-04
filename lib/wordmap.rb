require 'wordmap/version'
require 'wordmap/builder'
require 'wordmap/access'
require 'tmpdir'
require 'fileutils'

class Wordmap
  include Enumerable

  attr_reader :size

  SPACER = "\0".freeze
  LTRIM_REGEX = /\A#{SPACER}+/.freeze

  class << self
    def create(path, hash, index_names = [])
      raise ArgumentError, "Path already exists: #{path}" if Dir.exist?(path)

      index_data = index_names.map { |name| [name, {}] }.to_h
      vecs = Builder.build_vectors(hash)
      cells_c = vecs.map(&:size).reduce(:*)

      Dir.mktmpdir do |dirpath|
        vecs.each.with_index do |vec, i|
          Builder.write_vector("#{dirpath}/vec#{i}", vec, SPACER)
        end

        Builder.write_data(dirpath, vecs, cells_c, hash, SPACER) do |k, v, i|
          index_names.each do |name|
            index_keys = Array(yield(name, k, v)).compact
            next if index_keys.empty?
            index_keys.each do |index_key|
              index_data[name][index_key] ||= []
              index_data[name][index_key] << i
            end
          end
        end

        index_data.each do |name, data|
          next if data.empty?
          data.transform_values! { |v| IndexValue.pack(v) }
          create("#{dirpath}/i-#{name}.wmap", data)
        end

        FileUtils.cp_r(dirpath, path)
      end
    end
  end

  def initialize(path)
    @descriptors = Access.load_descriptors(Dir["#{path}/{vec*,data}"], SPACER)
    @indexes = load_indexes(Dir["#{path}/i-*"])
    @size = @descriptors['data'][:meta][:cell_count]
  end

  # Query consists of one or more clauses. Each clause is an array.
  #
  # Clauses can have 2 shapes:
  #
  #    1. ['key1', 'key2', ...] # match any of these main keys
  #    2. [:index_name, 'key1', 'key2', ...] # match by any of these index keys
  #
  # - OR logic is used inside a clause (matches are unioned)
  # - AND logic is used between clauses (matches are intersected)
  #
  # Example 1:
  #
  #     query(['horse1', 'horse2', 'horse3'], [:trait, 'fluffy'])
  #
  # Out of horse1, horse2, horse3 return only the fluffy ones.
  #
  # Example 2:
  #
  #    query([:color, 'orange', 'green'], [:type, 'vegetable', 'fruit'])
  #
  # Return all orange and green fruits and vegetables.
  def query(*query, trace: nil)
    enum =
      Access.each_by_query(@descriptors, @indexes, query, LTRIM_REGEX, trace)
    block_given? ? enum.each { |v| yield(v) } : enum
  end

  def [](*key, trace: nil)
    Access.each_by_key(@descriptors, key, LTRIM_REGEX, trace).to_a
  end

  def each(vec_or_index = nil, trace: nil)
    enum = Access.each(@descriptors, @indexes, vec_or_index, LTRIM_REGEX, trace)
    block_given? ? enum.each { |v| yield(v) } : enum
  end

  private

  def load_indexes(paths)
    paths.reduce({}) { |hash, path|
      name = File.basename(path, '.wmap')[2..-1].to_sym
      hash.merge(name => self.class.new(path))
    }
  end
end

