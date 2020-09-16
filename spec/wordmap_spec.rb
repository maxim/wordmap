RSpec.describe Wordmap do
  around do |ex|
    Dir.mktmpdir do |path|
      @wmap_path = "#{path}/test.wmap"
      ex.run
    end
  end

  def read(rel_path, path = @wmap_path)
    File.read("#{path}/#{rel_path}")
  end

  def reads_breakdown(trace)
    trace.map{ |r| [r[0], r[2].count { |v| v[0] == :read_cells }] }
  end

  context 'when wordmap is based on 1d hash without indexes' do
    let(:wmap) { Wordmap.new(@wmap_path) }

    before do
      Wordmap.create @wmap_path,
        '9780307946911' => 'In the Kingdom of Ice',
        '9785604041598' => 'Старинные люди у холодного океана',
        '9780385689229' => 'Born a Crime',
        '9781627790369' => 'Algorithms to Live By',
        '9785171144258' => 'Метро 2033',
        '9781400033553' => 'Americana'
    end

    it 'produces data, vecs, and index wmaps with correct content' do
      aggregate_failures do
        expect(read('data'))
          .to eq(
            "62,6\0"                              +
            ("\0" * 41) + 'In the Kingdom of Ice' +
            ("\0" * 50) + 'Born a Crime'          +
            ("\0" * 53) + 'Americana'             +
            ("\0" * 41) + 'Algorithms to Live By' +
            ("\0" * 47) + 'Метро 2033'            +
            'Старинные люди у холодного океана'
          )

        expect(read('vec0'))
          .to eq(
            "13,6\0"        \
            '9780307946911' \
            '9780385689229' \
            '9781400033553' \
            '9781627790369' \
            '9785171144258' \
            '9785604041598'
          )
      end
    end

    describe '#each' do
      it 'accepts a block and traverses data' do
        titles = []
        wmap.each { |title| titles << title }

        expect(titles)
          .to eq(['In the Kingdom of Ice',
                  'Born a Crime',
                  'Americana',
                  'Algorithms to Live By',
                  'Метро 2033',
                  'Старинные люди у холодного океана'])
      end

      it 'returns an efficient enum when block is not given' do
        trace = []
        enum = wmap.each(trace: trace)
        expect(enum).to be_a_kind_of(Enumerator)
        expect(enum.next).to eq('In the Kingdom of Ice')
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
        expect(enum.next).to eq('Born a Crime')
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end

      it 'uses a 1 read to access everything' do
        trace = []
        wmap.each(trace: trace) { |book_title| book_title }
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end

      it 'can traverse a vector' do
        trace = []
        isbns = wmap.each(0, trace: trace).to_a
        expect(isbns).to eq(%w[
          9780307946911
          9780385689229
          9781400033553
          9781627790369
          9785171144258
          9785604041598
        ])

        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end
    end

    describe '#[]' do
      it 'returns values by key using bsearch and read (3 reads total)' do
        trace = []
        expect(wmap['9780385689229', trace: trace]).to eq(['Born a Crime'])
        expect(reads_breakdown(trace))
          .to eq([[:bsearch_vec, 2], [:each_by_key, 1]])
      end

      it 'returns empty array for unknown keys' do
        trace = []
        expect(wmap['wrong-isbn', trace: trace]).to eq([])
        expect(reads_breakdown(trace)).to eq([[:bsearch_vec, 3]])
      end

      it 'does thread safe lookups' do
        wmap['9780385689229'] # Seeking in parent thread.
        concurrency = 100

        threads = concurrency.times.map {
          Thread.new { Thread.current[:book] = !wmap['9780385689229'][0].nil? }
        }

        success_count = threads.map { |t| t.join[:book] }.count(&:itself)
        expect(success_count).to eq(concurrency),
          "#{success_count}/#{threads.size} threads succeeded"
      end
    end

    describe '#query' do
      subject { wmap.query(*query, trace: trace).to_a }
      let(:trace) { [] }

      context 'when query is (9780385689229)' do
        let(:query) { ['9780385689229'] }

        it 'returns result after 1 bsearch and 1 data read' do
          expect(subject.to_a).to eq(['Born a Crime'])

          aggregate_failures do
            expect(reads_breakdown(trace))
              .to eq([[:bsearch_vec, 2], [:each_by_query, 1]])
          end
        end
      end

      context 'when query is (9780385689229, 9780307946911)' do
        let(:query) { %w[9780385689229 9780307946911] }

        it 'returns a union of results in 2 bsearches and 1 data read' do
          expect(subject).to eq(['In the Kingdom of Ice', 'Born a Crime'])
          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 3],
              [:bsearch_vec, 2],
              [:each_by_query, 1]
            ])
        end
      end

      context 'when query is ([9780385689229, 9780307946911])' do
        let(:query) { [%w[9780385689229 9780307946911]] }

        it 'returns a union of results in 2 bsearches and 1 data read' do
          expect(subject)
            .to eq(['In the Kingdom of Ice', 'Born a Crime'])

          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 3],
              [:bsearch_vec, 2],
              [:each_by_query, 1]
            ])
        end
      end

      context 'when query is ([9780385689229], [9780307946911])' do
        let(:query) { [%w[9780385689229], %w[9780307946911]] }

        it 'intersects keys and returns without unnecessary data reads' do
          expect(subject).to eq([])
          expect(reads_breakdown(trace)).to eq([])
        end
      end

      context 'when query has keys that cannot possibly intersect' do
        let(:query) {
          [%w[9780307946911 9780385689229 9781627790369], %w[9780307946911]]
        }

        it 'returns 1 valid intersection without unnecessary reads' do
          expect(subject).to eq(['In the Kingdom of Ice'])
          expect(reads_breakdown(trace))
            .to eq([[:bsearch_vec, 3], [:each_by_query, 1]])
        end
      end

      it 'raises error on unknown index' do
        aggregate_failures do
          expect { wmap.query(:fake, 'foo').to_a }.to raise_error(/fake/)
          expect { wmap.query([:fake, 'foo']).to_a }.to raise_error(/fake/)
        end
      end
    end
  end

  context 'when wordmap is based on 1d hash with indexes' do
    before do
      Wordmap.create(@wmap_path, {
        '9780307946911' => 'In the Kingdom of Ice',
        '9785604041598' => 'Старинные люди у холодного океана',
        '9780385689229' => 'Born a Crime',
        '9781627790369' => 'Algorithms to Live By',
        '9785171144258' => 'Метро 2033',
        '9781400033553' => 'Americana'
      }, %w[author year]) do |index, key, value|
        index_keys =
          case key
          when '9780307946911'; ['Hampton Sides',      '2014']
          when '9785604041598'; ['Владимир Зензинов',  '1914']
          when '9780385689229'; ['Trevor Noah',        '2016']
          when '9781627790369'; ['Brian Christian',    '2016']
          when '9785171144258'; ['Дмитрий Глуховский', '2002']
          when '9781400033553'; ['Hampton Sides',      '2004']
          end

        index == 'author' ? index_keys[0] : index_keys[1]
      end
    end

    it 'produces data, vecs, and index wmaps with correct content' do
      aggregate_failures do
        expect(read('data'))
          .to eq(
            "62,6\0"                              +
            ("\0" * 41) + 'In the Kingdom of Ice' +
            ("\0" * 50) + 'Born a Crime'          +
            ("\0" * 53) + 'Americana'             +
            ("\0" * 41) + 'Algorithms to Live By' +
            ("\0" * 47) + 'Метро 2033'            +
            'Старинные люди у холодного океана'
          )

        expect(read('vec0'))
          .to eq(
            "13,6\0"        \
            '9780307946911' \
            '9780385689229' \
            '9781400033553' \
            '9781627790369' \
            '9785171144258' \
            '9785604041598'
          )

        expect(read('i-author.wmap/data'))
          .to eq(
            "3,5\0" +
            "\0\0"  + '3' +
            '0,2'   +
            "\0\0"  + '1' +
            "\0\0"  + '5' +
            "\0\0"  + '4'
          )

        expect(read('i-author.wmap/vec0'))
          .to eq(
            "35,5\0"                          +
            ("\0" * 20) + 'Brian Christian'   +
            ("\0" * 22) + 'Hampton Sides'     +
            ("\0" * 24) + 'Trevor Noah'       +
            ("\0" * 2 ) + 'Владимир Зензинов' +
            'Дмитрий Глуховский'
          )

        expect(read('i-year.wmap/data'))
          .to eq(
            "3,5\0" +
            "\0\0"  + '5' +
            "\0\0"  + '4' +
            "\0\0"  + '2' +
            "\0\0"  + '0' +
            '1,2'
          )

        expect(read('i-year.wmap/vec0'))
          .to eq("4,5\0" + '19142002200420142016')
      end
    end
  end

  context 'when wordmap is based on 2d hash with indexes' do
    let(:wmap) { Wordmap.new(@wmap_path) }

    before do
      Wordmap.create(@wmap_path, {
        ['9780', '307946911'] => 'In the Kingdom of Ice',
        ['9785', '604041598'] => 'Старинные люди у холодного океана',
        ['9780', '385689229'] => 'Born a Crime',
        ['9781', '627790369'] => 'Algorithms to Live By',
        ['9785', '171144258'] => 'Метро 2033',
        ['9781', '400033553'] => 'Americana'
      }, %w[author year]) do |index, key, value|
        index_keys =
          case key
          when ['9780', '307946911']; ['Hampton Sides',      '2014']
          when ['9785', '604041598']; ['Владимир Зензинов',  '1914']
          when ['9780', '385689229']; ['Trevor Noah',        '2016']
          when ['9781', '627790369']; ['Brian Christian',    '2016']
          when ['9785', '171144258']; ['Дмитрий Глуховский', '2002']
          when ['9781', '400033553']; ['Hampton Sides',      '2004']
          end

        index == 'author' ? index_keys[0] : index_keys[1]
      end
    end

    it 'produces data, vecs, and index wmaps with correct content' do
      aggregate_failures do
        expect(read('data'))
          .to eq(
            "62,18\0"                             +

            ("\0" * 62)                           + # 0
            ("\0" * 41) + 'In the Kingdom of Ice' + # 1
            ("\0" * 50) + 'Born a Crime'          + # 2
            ("\0" * 62 * 3)                       + # 3,4,5

            ("\0" * 62 * 3)                       + # 6,7,8
            ("\0" * 53) + 'Americana'             + # 9
            ("\0" * 62)                           + # 10
            ("\0" * 41) + 'Algorithms to Live By' + # 11

            ("\0" * 47) + 'Метро 2033'            + # 12
            ("\0" * 62 * 3)                       + # 13,14,15
            'Старинные люди у холодного океана'   + # 16
            ("\0" * 62)                             # 17
          )

        expect(read('vec0'))
          .to eq(
            "4,3\0" \
            '9780'  \
            '9781'  \
            '9785'
          )

        expect(read('vec1'))
          .to eq(
            "9,6\0"     \
            '171144258' \
            '307946911' \
            '385689229' \
            '400033553' \
            '604041598' \
            '627790369'
          )

        expect(read('i-author.wmap/data'))
          .to eq(
            "3,5\0" +
            "\0"    +  '11' +
                      '1,8' +
            "\0\0"  +   '2' +
            "\0"    +  '16' +
            "\0"    +  '12'
          )

        expect(read('i-author.wmap/vec0'))
          .to eq(
            "35,5\0"                          +
            ("\0" * 20) + 'Brian Christian'   +
            ("\0" * 22) + 'Hampton Sides'     +
            ("\0" * 24) + 'Trevor Noah'       +
            ("\0" * 2 ) + 'Владимир Зензинов' +
            'Дмитрий Глуховский'
          )

        expect(read('i-year.wmap/data'))
          .to eq(
            "3,5\0" +
            "\0"    +  '16' +
            "\0"    +  '12' +
            "\0\0"  +   '9' +
            "\0\0"  +   '1' +
                      '2,9'
          )

        expect(read('i-year.wmap/vec0'))
          .to eq("4,5\0" + %w[1914 2002 2004 2014 2016].join)
      end
    end

    describe '#each' do
      it 'accepts a block and traverses data' do
        titles = []
        wmap.each { |title| titles << title }

        expect(titles)
          .to eq(['In the Kingdom of Ice',
                  'Born a Crime',
                  'Americana',
                  'Algorithms to Live By',
                  'Метро 2033',
                  'Старинные люди у холодного океана'])
      end

      it 'returns an efficient enum when block is not given' do
        trace = []
        enum = wmap.each(trace: trace)
        expect(enum).to be_a_kind_of(Enumerator)
        expect(enum.next).to eq('In the Kingdom of Ice')
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
        expect(enum.next).to eq('Born a Crime')
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end

      it 'uses a 1 read to access everything' do
        trace = []
        wmap.each(trace: trace) { |book_title| book_title }
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end

      it 'can traverse vec0' do
        trace = []
        isbns = wmap.each(0, trace: trace).to_a
        expect(isbns).to eq(%w[9780 9781 9785 ])
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end

      it 'can traverse vec1' do
        trace = []
        isbns = wmap.each(1, trace: trace).to_a
        expect(isbns).to eq(%w[
          171144258
          307946911
          385689229
          400033553
          604041598
          627790369
        ])

        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end

      it 'can traverse year index' do
        trace = []
        years = wmap.each(:year, trace: trace).to_a
        expect(years).to eq(%w[1914 2002 2004 2014 2016])
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end

      it 'can traverse author index' do
        trace = []
        authors = wmap.each(:author, trace: trace).to_a
        expect(authors).to eq([
          'Brian Christian',
          'Hampton Sides',
          'Trevor Noah',
          'Владимир Зензинов',
          'Дмитрий Глуховский'
        ])
        expect(reads_breakdown(trace)).to eq([[:each, 1]])
      end
    end

    describe '#[]' do
      it 'returns values by key using 2 bsearches and read (4 reads total)' do
        trace = []
        expect(wmap['9780', '385689229', trace: trace]).to eq(['Born a Crime'])
        expect(reads_breakdown(trace))
          .to eq([[:bsearch_vec, 2], [:bsearch_vec, 1], [:each_by_key, 1]])
      end

      it 'returns empty array for unknown keys' do
        trace = []
        expect(wmap['wrong-isbn', trace: trace]).to eq([])
        expect(reads_breakdown(trace)).to eq([[:bsearch_vec, 2]])
      end

      it 'returns all subkeys for a single key part' do
        trace = []
        expect(wmap['9780', trace: trace])
          .to eq(['In the Kingdom of Ice', 'Born a Crime'])
        expect(reads_breakdown(trace))
          .to eq([[:bsearch_vec, 2], [:each_by_key, 1]])
      end
    end

    describe '#query' do
      subject { wmap.query(*query, trace: trace).to_a }
      let(:trace) { [] }

      context 'when query is ([[9780, 385689229]])' do
        let(:query) { [[%w[9780 385689229]]] }

        it 'returns result after 2 bsearches and 1 data read' do
          expect(subject.to_a).to eq(['Born a Crime'])
          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 2],
              [:bsearch_vec, 1],
              [:each_by_query, 1]
            ])
        end
      end

      context 'when query is ([[9780, 385689229], [9780, 307946911]])' do
        let(:query) { [[%w[9780 385689229], %w[9780 307946911]]] }

        it 'returns a union of results in 2 bsearches and 1 data read' do
          expect(subject).to eq(['In the Kingdom of Ice', 'Born a Crime'])
            expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 2],
              [:bsearch_vec, 2],
              [:bsearch_vec, 2],
              [:bsearch_vec, 1],
              [:each_by_query, 1]
            ])
        end
      end

      context 'when query is ([[9780, 385689229], [9780, 307946911]])' do
        let(:query) { [[%w[9780 385689229]], [%w[9780 307946911]]] }

        it 'intersects keys and returns without unnecessary data reads' do
          expect(subject).to eq([])
          expect(reads_breakdown(trace)).to eq([])
        end
      end

      context 'when query has keys that cannot possibly intersect' do
        let(:query) {[
          [%w[9780 307946911], %w[9780 385689229], %w[9781 627790369]],
          [%w[9780 307946911]]
        ]}

        it 'returns 1 valid intersection without unnecessary reads' do
          expect(subject).to eq(['In the Kingdom of Ice'])
          expect(reads_breakdown(trace))
            .to eq([[:bsearch_vec, 2], [:bsearch_vec, 2], [:each_by_query, 1]])
        end
      end

      context 'when query: (:author, "Владимир Зензинов")' do
        let(:query) { [:author, 'Владимир Зензинов'] }

        it 'returns result by index' do
          expect(subject).to eq(['Старинные люди у холодного океана'])
          expect(reads_breakdown(trace))
            .to eq([[:bsearch_vec, 2], [:each_by_key, 1], [:each_by_query, 1]])
        end
      end

      context 'when query: (:year, "2016")' do
        let(:query) { [:year, '2016'] }

        it 'returns results by index' do
          expect(subject).to eq(['Born a Crime', 'Algorithms to Live By'])
          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 3],
              [:each_by_key, 1],
              [:each_by_query, 1],
              [:each_by_query, 1]
            ])
        end
      end

      context 'when query: ([:year, "2016", "2002"])' do
        let(:query) { [:year, '2016', '2002'] }

        it 'returns results by index' do
          expect(subject)
            .to eq(['Born a Crime', 'Algorithms to Live By', 'Метро 2033'])

          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 3],
              [:each_by_key, 1],
              [:bsearch_vec, 2],
              [:each_by_key, 1],
              [:each_by_query, 1],
              [:each_by_query, 1]
            ])
        end
      end

      context 'when query: ([:year, "2016", "2002"], [[9780, 385689229]]' do
        let(:query) { [[:year, '2016', '2002'], [%w[9780 385689229]]] }

        it 'returns results by intersected indexes' do
          expect(subject).to eq(['Born a Crime'])

          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 3],
              [:each_by_key, 1],
              [:bsearch_vec, 2],
              [:each_by_key, 1],
              [:bsearch_vec, 2],
              [:bsearch_vec, 1],
              [:each_by_query, 1]
            ])
        end
      end

      context 'when query: ([:year, "2016", "2002"], [:year, 2002])' do
        let(:query) { [[:year, '2016', '2002'], [:year, '2002']] }

        it 'collapses the query to save on reads' do
          expect(subject).to eq(['Метро 2033'])

          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 2],
              [:each_by_key, 1],
              [:each_by_query, 1]
            ])
        end
      end

      context 'when query: ([:year, "2014", "2016"], '\
                           '[:author, "Hampton Sides", "Trevor Noah"])' do

        let(:query) { [
          [:year, '2014', '2016'],
          [:author, 'Hampton Sides', 'Trevor Noah']
        ] }

        it 'reads as much as needed when traversing the results' do
          enum = wmap.query(*query, trace: trace)
          expect(enum.next).to eq('In the Kingdom of Ice')
          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 2],
              [:each_by_key, 1],
              [:bsearch_vec, 3],
              [:each_by_key, 1],
              [:bsearch_vec, 2],
              [:each_by_key, 1],
              [:bsearch_vec, 1],
              [:each_by_key, 1],
              [:each_by_query, 1]
            ])
          expect(enum.next).to eq('Born a Crime')
          expect(reads_breakdown(trace))
            .to eq([
              [:bsearch_vec, 2],
              [:each_by_key, 1],
              [:bsearch_vec, 3],
              [:each_by_key, 1],
              [:bsearch_vec, 2],
              [:each_by_key, 1],
              [:bsearch_vec, 1],
              [:each_by_key, 1],
              [:each_by_query, 1]
            ])
        end
      end

      it 'raises error on unknown index' do
        aggregate_failures do
          expect { wmap.query(:fake, 'foo').to_a }.to raise_error(/fake/)
          expect { wmap.query([:fake, 'foo']).to_a }.to raise_error(/fake/)
        end
      end
    end
  end

  context 'when wordmap is based on 3d hash with indexes' do
    before do
      Wordmap.create(@wmap_path, {
        ['9780', '3', '07946911'] => 'In the Kingdom of Ice',
        ['9785', '6', '04041598'] => 'Старинные люди у холодного океана',
        ['9780', '3', '85689229'] => 'Born a Crime',
        ['9781', '6', '27790369'] => 'Algorithms to Live By',
        ['9785', '1', '71144258'] => 'Метро 2033',
        ['9781', '4', '00033553'] => 'Americana'
      }, %w[author year]) do |index, key, value|
        index_keys =
          case key
          when ['9780', '3', '07946911']; ['Hampton Sides',      '2014']
          when ['9785', '6', '04041598']; ['Владимир Зензинов',  '1914']
          when ['9780', '3', '85689229']; ['Trevor Noah',        '2016']
          when ['9781', '6', '27790369']; ['Brian Christian',    '2016']
          when ['9785', '1', '71144258']; ['Дмитрий Глуховский', '2002']
          when ['9781', '4', '00033553']; ['Hampton Sides',      '2004']
          end

        index == 'author' ? index_keys[0] : index_keys[1]
      end
    end

    it 'produces data, vecs, and index wmaps with correct content' do
      aggregate_failures do
        expect(read('data'))
          .to eq(
            "62,72\0"                             +

            # 9780:1
            ("\0" * 62 * 6)                       + # 0-5

            # 9780:3
            ("\0" * 62 * 2)                       + # 6,7
            ("\0" * 41) + 'In the Kingdom of Ice' + # 8
            ("\0" * 62 * 2)                       + # 9,10
            ("\0" * 50) + 'Born a Crime'          + # 11

            # 9780:4 - 9781:3
            ("\0" * 62 * 24)                      + # 12-35

            # 9781:4
            ("\0" * 53) + 'Americana'             + # 36
            ("\0" * 62 * 5)                       + # 37-41

            # 9781:6
            ("\0" * 62 * 3)                       + # 42-44
            ("\0" * 41) + 'Algorithms to Live By' + # 45
            ("\0" * 62 * 2)                       + # 46,47

            # 9785:1
            ("\0" * 62 * 4)                       + # 48-51
            ("\0" * 47) + 'Метро 2033'            + # 52
            ("\0" * 62)                           + # 53

            # 9785:3 - 9785:4
            ("\0" * 62 * 12)                      + # 54-65

            # 9785:6
            ("\0" * 62 * 1)                       + # 66
            'Старинные люди у холодного океана'   + # 67
            ("\0" * 62 * 4)                         # 68-71
          )

        expect(read('vec0'))
          .to eq(
            "4,3\0" \
            '9780'  \
            '9781'  \
            '9785'
          )

        expect(read('vec1'))
          .to eq(
            "1,4\0" \
            '1'     \
            '3'     \
            '4'     \
            '6'
          )

        expect(read('vec2'))
          .to eq(
            "8,6\0"    \
            '00033553' \
            '04041598' \
            '07946911' \
            '27790369' \
            '71144258' \
            '85689229'
          )

        expect(read('i-author.wmap/data'))
          .to eq(
            "4,5\0" +
            "\0\0"    +   '45' +
                        '8,28' +
            "\0\0"    +   '11' +
            "\0\0"    +   '67' +
            "\0\0"    +   '52'
          )

        expect(read('i-author.wmap/vec0'))
          .to eq(
            "35,5\0"                          +
            ("\0" * 20) + 'Brian Christian'   +
            ("\0" * 22) + 'Hampton Sides'     +
            ("\0" * 24) + 'Trevor Noah'       +
            ("\0" * 2 ) + 'Владимир Зензинов' +
            'Дмитрий Глуховский'
          )

        expect(read('i-year.wmap/data'))
          .to eq(
            "5,5\0"    +
            "\0\0\0"   +    '67' +
            "\0\0\0"   +    '52' +
            "\0\0\0"   +    '36' +
            "\0\0\0\0" +     '8' +
                       '11,34'
          )

        expect(read('i-year.wmap/vec0'))
          .to eq("4,5\0" + %w[1914 2002 2004 2014 2016].join)
      end
    end
  end
end
