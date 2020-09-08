# Wordmap

A simple way to look up UTF-8 strings on disk by key(s) or index-powered queries without using any RAM.

Useful in cases where:

* RAM is more important than data access speed (1-3k reads/sec depending on SSD)
* Data is read-only (perhaps vendored with your repo)
* Your dataset might have many values, but they are not outrageously long or varied in size (the biggest value defines the "cell" size in the wordmap, and all others are padded to it)

## Installation

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

In the above code snippet we specify the path where wordmap will be stored, the data itself (`entries`), and the optional 3rd argument, which lists any indexes we'd like to create. If a 3rd argument is given, then you must also supply a block. In this block you will get each `index_name`, `key`, and `value` combination, and your job is to return the corresponding index key for that combination.

### Querying

You can query a wordmap 3 different ways.

#### 1. By key(s)

```ruby
fruits = Wordmap.new('path/to/fruits.wmap')
wordmap['banana'] # => ['14']
```

#### 2. By query

A query is an array of arrays. Inner arrays are treated like unions (everything in them is `OR`'ed). Outer array is treated as an intersection (results of inner arrays are `AND`'ed with one another).

If an inner array starts with a symbol, the symbol is treated as an index name you want to look in.

```ruby
fruits = Wordmap.new('path/to/fruits.wmap')
fruits.query(%w[banana lemon]).to_a # => ["14", "49"]
fruits.query([:color, 'yellow']).to_a # => ["14", "49"]
fruits.query([:genus, 'citrus'], [:color, 'yellow']).to_a # => ["49"]
fruits.query(%w[lemon banana], [:genus, 'citrus']).to_a # => ["49"]
```

**Result format**

The result is always a lazy enumerable of UTF-8 strings, which is why you see  `.to_a` called on each of them. Wordmap is trying to read files as lazily as possible.

**Result order**

The result values are in the order of how data is arranged in the wordmap's data file, which itself is based on lexicographical sorting of keys.

Tip: If you are only supplying 1 array (as in the first and second examples above), you can drop the array wrapper.

```ruby
fruits.query('banana', 'lemon')
fruits.query(:color, 'yellow')
```

#### 3. Sequentially

If you just want to read all values sequentially, you can treat a wordmap as an [Enumerable](https://ruby-doc.org/core/Enumerable.html).

```ruby
fruits.select { |price| price.to_i < 40 } # => ["14"]
```

You have access to `.each` method, but it also accepts an argument. If you pass an integer, you can iterate over a single vector (a key dimension, see [Multi-dimensional keys](#multi-dimensional-keys) ). Since fruits is 1-dimensional array, you can only iterate over 0th dimension.

```ruby
fruits.each(0).to_a # => ["banana", "lemon"]
```

You can pass a symbol to iterate sequentially over index keys.

```ruby
fruits.each(:genus).to_a # => ["citrus", "musa"]
```

### Multi-dimensional keys

TODO.

## Anatomy

TODO.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/wordmap. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/wordmap/blob/master/CODE_OF_CONDUCT.md).


## Code of Conduct

Everyone interacting in the Wordmap project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/wordmap/blob/master/CODE_OF_CONDUCT.md).
