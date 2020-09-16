![RSpec](https://github.com/scottscheapflights/wordmap/workflows/RSpec/badge.svg)

# Wordmap

A simple way to look up UTF-8 strings on disk by key(s) or index-powered queries without using any RAM.

Useful in cases where:

* RAM is more important than data access speed (1-3k reads/sec depending on SSD)
* Data is read-only (perhaps vendored with your repo)
* Your dataset might have many values, but they are not outrageously long or varied in size (the biggest value defines the "cell" size in the wordmap, and all others are padded to it)

## Installation

Note: Requires at least ruby 2.5 to support `File#pread` function.

Add this line to your application's Gemfile:

```ruby
gem 'wordmap'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install wordmap

## Usage

Before we can query a wordmap, we must create one first.

### Creating

Imagine you are storing fruit prices in cents, and fruits are also indexed by color and genus.

```ruby
entries = { 'banana' => '14',     'lemon' => '49' }
color   = { 'banana' => 'yellow', 'lemon' => 'yellow' }
genus   = { 'banana' => 'musa',   'lemon' => 'citrus' }
```

Now given the above 3 hashes, you can create a wordmap like this:

```ruby
Wordmap.create('path/to/fruits.wmap', entries, [:color, :genus]) do |index_name, key, value|
  if index_name == :color
    color[key]
  else
    genus[key]
  end
end
```

In the above code snippet we specify the path where wordmap will be stored, the data itself (`entries`), and the optional 3rd argument, which lists any indexes we'd like to create. If a 3rd argument is given, then you must also supply a block. In this block you will get each `index_name`, `key`, and `value` combination from your entries, and your job is to return the corresponding index key for that combination.

### Querying

You can query a wordmap in 3 different ways.

#### 1. By key(s)

```ruby
fruits = Wordmap.new('path/to/fruits.wmap')
wordmap['banana'] # => ['14']
```

#### 2. By query

```ruby
fruits = Wordmap.new('path/to/fruits.wmap')

# Give me prices for banana and lemon.
fruits.query(%w[banana lemon]).to_a # => ["14", "49"]

# Give me prices for all yellow fruits.
fruits.query([:color, 'yellow']).to_a # => ["14", "49"]

# Give me prices for all yellow citruses.
fruits.query([:genus, 'citrus'], [:color, 'yellow']).to_a # => ["49"]

# Out of lemon and banana, give me prices for only citrus ones.
fruits.query(%w[lemon banana], [:genus, 'citrus']).to_a # => ["49"]
```

Each query is an array of arrays (outer array is omitted in the examples, because it works either way). Inner arrays are treated like unions (everything in them is `OR`'ed). Outer array is treated as an intersection (results of inner arrays are `AND`'ed with one another).

If an inner array starts with a symbol, the symbol is treated as an index name you want to look in.

Tip: if you are only supplying 1 array (as in the first and second examples above), you can drop all array wrappers entirely.

```ruby
fruits.query('banana', 'lemon')
fruits.query(:color, 'yellow')
```

**Result format**

The result is always a lazy enumerable of UTF-8 strings, which is why you see me call  `.to_a` on each of them. Wordmap is trying to read files as lazily as possible.

**Results order**

The result values are in the order of how data is arranged in the wordmap's data file, which itself is based on lexicographical sorting of keys.

#### 3. Sequentially

If you just want to read all values sequentially, you can treat a wordmap as an [Enumerable](https://ruby-doc.org/core/Enumerable.html).

```ruby
fruits.select { |price| price.to_i < 40 } # => ["14"]
```

You have access to `.each` method, but it also accepts an argument. If you pass an integer, you can iterate over a single vector (a key dimension, see [Multi-dimensional keys](#multi-dimensional-keys) ). Since fruits is 1-dimensional array, you can only iterate over 0th dimension.

```ruby
fruits.each.to_a # => ["14", "49"]
fruits.each(0).to_a # => ["banana", "lemon"]
```

You can pass a symbol to iterate sequentially over index keys.

```ruby
fruits.each(:genus).to_a # => ["citrus", "musa"]
```

### Multi-dimensional keys

In the above examples the keys are simply `'banana'` and `'lemon'` — strings. If you make your key an array of strings, that'd make a multi-dimensional key. This can come helpful for some data where 2 keys make sense (we have such use cases at Scott's). Internally, each dimension is a different vector. However if you go that route, keep in mind that all the "unused" key combinations will create gaps in the data file, therefore inflating its size. For example, if you make a key out of genus + name of a fruit, like `%w[citrus lemon]` and `%w[musa banana]`, your file will become inflated with empty cells created for `%w[citrus banana]`, `%w[musa lemon]`. That space is taken (padded with null bytes) even if there are no values for these keys.

## Anatomy

A wordmap on disk is just a directory with a few files in it.

### `data` file

The data file is where the actual entries are stored. When a wordmap is created, it looks through all the entries you want to store, and finds one with the maximum bytesize. Then it makes all entries that size by padding them with null bytes in front, and dumping all of them into the file. Since this makes each entry in the file the same size, we can easily seek to any single entry by knowing its index, because it's just index times entry size. We call such padded entry a "cell".

The important part is the order of data in this file. When a wordmap is created, all the keys are sorted lexicographically, and for every key, entry is written in the order of how the corresponding keys are sorted. This means that if we know index of where a key is positioned sequentially, we also know index of where the cell is in the data file.

### `vec` files

Vector files are where keys are stored. If you used a string as a lookup key, then it creates just one vector file where every key is written in a cell padded to maximum key length just like the case with the data file. Since this file is sorted, we can easily binary-search a key in this file, and then seek to corresponding position in the data file to find the entry.

For multi-dimensional keys, multiple vector files are created (one per dimension). Let's say we have 2-dimensional key (a key that's an array of 2 strings). The first vector will contain all the first strings, and second all the second strings. Now when wordmap is doing a lookup by key, it will first bsearch the first vector to find a "page" of entries in the data file, then it will bsearch the second vector to find an exact entry position in that page of entries. Then it will know exactly where to seek to grab the entry from the data file.

### Metadata

Data and vector files each have a couple of numbers at the beginning that specify cells' bytesize and count. This is the only part that wordmap reads into RAM when instantiated: 2 integers per file. Having read metadata we can derive 2 additional pieces of information: 1. the bytesize of the metadata itself, so that we can skip over it, and 2. how many cells we should read every time we read a lot of cells (to optimize sequential reads). The latter is always trying to be near ~10kb per read (unless a single cell is longer than 10kb, then it's using single cell's size).

### Indexes

Indexes are just wordmaps nested inside the wordmap you create. These inner wordmaps have index keys as the keys, and lists of locations as values. The values of indexes are invisible to the end user, but since this section is about anatomy, it makes sense to mention them. The locations are stored as a comma-separated list of [delta encoded](https://en.wikipedia.org/wiki/Delta_encoding) sorted integers and ranges. For example, if we are storing locations `1,3,5,6,7,8,12,15` the stored value will look like this: `1,2,2+3,4,3`. You can unpack this value by saying "first position is **1**, second position is 1 + 2 = **3**, third position is 3 + 2 = **5**, now add 3 more successively: **6,7,8**, then 8 + 4 = **12**, and 12 + 3 = **15**".

When processing a query, wordmap produces lazy iterators for unioning and intersecting data. These iterators lazily walk indexed locations, or keys in a vector file, and return each found entry from the data file.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/wordmap. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/wordmap/blob/main/CODE_OF_CONDUCT.md).


## Code of Conduct

Everyone interacting in the Wordmap project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/wordmap/blob/main/CODE_OF_CONDUCT.md).
