#full-text search index
require 'ferret'
#xml
require 'libxml'
include LibXML

#constants
require BASE_PATH + '/lib/constants'
require BASE_PATH + '/lib/entry'
require BASE_PATH + '/lib/kanji'
require BASE_PATH + '/lib/kana'

Ferret.locale = "en_US.UTF-8" # Ensure that Ferret is unicode friendly
                              # TODO: make sure en_US.UTF-8 is the correct constant

class DictIndex
  include Constants
  include Constants::JMDict
  include Ferret
  
  LANGUAGE_DEFAULT = Constants::JMDict::Languages::ENGLISH
  NUM_ENTRIES_TO_INDEX = 500
  
  attr_reader :path
  def initialize(index_path, dictionary_path=nil, lazy_loading=true)
    
    raise Exception.new("Index path was nil") if index_path.nil?
    raise Exception.new("Index not found at path #{index_path}") unless File.exists? index_path

    path_specified = dictionary_path.nil? ? false : true
    if path_specified and not File.exists? dictionary_path
      raise Exception.new("Dictionary not found at path #{dictionary_path}")
    end

    @path = index_path
    @dictionary_path = dictionary_path

    #analyzer
    analyzer    = Analysis::PerFieldAnalyzer.new(Analysis::StandardAnalyzer.new)
    re_analyzer = Analysis::RegExpAnalyzer.new(/./, false)
    (0..10).map { |x| analyzer["kana_#{x}".intern] = re_analyzer }
    analyzer[:kanji] = re_analyzer
    
    create_index = lazy_loading ? false : true
    @ferret_index = Index::Index.new(:path     => @path,
                                     :analyzer => analyzer,
                                     :create   => create_index)
    build unless lazy_loading
  end
  
  def built?; File.exists? @path; end
  
  # build the full-text search index
  #   overwrite: force a build even if the index path already exists
  #   returns the number of indexed entries
  #
  def build(overwrite=false, dictionary_path=nil)
    @dictionary_path = dictionary_path unless dictionary_path.nil?
    raise Exception.new("No dictionary path was provided") if @dictionary_path.nil?
    raise Exception.new("Dictionary not found at path #{@dictionary_path}") unless File.exists?(@dictionary_path)    
    
    # open reader
    reader = nil
    Dir.chdir(Dir.pwd) do
      jmdict_path = File.join(@dictionary_path)
      reader = XML::Reader.file(jmdict_path) # create a reader for JMdict
      raise "Failed to create XML::Reader for #{@dictionary_path}!" if reader.nil?
    end
    # whenever there is a reader error, print its block parameters
    reader.set_error_handler { |*args| p args }

    # components of an entry
    kanji, kana, senses = [], [], []
    glosses = {}
    part_of_speech = nil
  
    # read until the end
    while reader.read > 0
    
      # check what type of node we're currently on
      case reader.node_type

        # start-of-element node
        when XML::Reader::TYPE_ELEMENT
          case reader.name
            when JMDict::Elements::SEQUENCE
              entry_sequence_num = reader.next_text

            # TODO: Raise an exception if reader.next_text.empty? inside the when's
            #       JMdict shouldn't have any empty elements, I believe.
            when JMDict::Elements::KANJI
              text = reader.next_text
              kanji << text unless text.empty?

            when JMDict::Elements::KANA
              text = reader.next_text
              kana << text unless text.empty?

            when JMDict::Elements::GLOSS
              # TODO: bug— language is always 'en', even when gloss is not english
              language = reader[JMDict::Attributes::LANGUAGE] || LANGUAGE_DEFAULT
              text = reader.next_text
              unless text.empty?
                (glosses[language] ||= []) << text
              end

            # TODO: Add xmlTextReaderGetParserProp and xmlTextReaderSetParserProp
            #       support to libxml-ruby.
            #       Then set the SUBST_ENTITIES property and uncomment
            #       this 'when' clause. Hopefully it will be able to read
            #       part-of-speeches then
            # when PART_OF_SPEECH_ELEMENT
            #   part_of_speech = reader.next_text
          end

        # end-of-element node
        when XML::Reader::TYPE_END_ELEMENT
          case reader.name

            when JMDict::Elements::SENSE
              # build sense
              senses << Sense.new(part_of_speech, glosses)
              # glosses.each do |language, texts|
              #   senses << Sense.new(part_of_speech,
              #                       texts.join(', ').strip,
              #                       language)
              # end
          
            
              # clear data for the next sense
              glosses = {}
              part_of_speech = nil

            # we're at the end of the entry element, so index it
            when JMDict::Elements::ENTRY
              raise "No kana found for this entry!" if kana.empty?
              
              #index
              @ferret_index << Entry.new(kanji, kana, senses).to_index_doc
              
              # TODO: add entry_sequence_num to the entry

              # clear data for the next entry
    		      kanji, kana, senses = [], [], []

              # DEBUG
              break if @ferret_index.size >= NUM_ENTRIES_TO_INDEX
              # if @ferret_index.size.modulo(1000) == 0
              if @ferret_index.size.modulo(100) == 0
                # puts "#{@ferret_index.size/1000} thousand"
                puts "#{@ferret_index.size/100} hundred"
              end
          end
      end
    end
  
    # Done reading & indexing
    reader.close
    @ferret_index.close
  end
  def rebuild
    if File.exists? @path
      raise Exception.new("Index already exists at path #{@path}")
    else
      build
    end
  end
end

# Add custom parsing methods to XML::Reader
class XML::Reader
public
  # Get the next text node
  def next_text
    # read until a text node
    while (self.node_type != XML::Reader::TYPE_TEXT and self.read > 0); end
    self.value
  end

  # Get the next entity node
  def next_entity
    # read until an entity node
    while (self.node_type != XML::Reader::TYPE_ENTITY and
           self.node_type != XML::Reader::TYPE_ENTITY_REFERENCE and
           self.read > 0); end
    self.value
  end
end