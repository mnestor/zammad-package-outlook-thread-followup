# Runs Channel::Filter::FollowUpThreadIndex outside Zammad against minimal
# stand-ins for the Rails and Zammad classes it touches:
#
#   ruby test/follow_up_thread_index_test.rb
require 'base64'
require 'logger'
require 'minitest/autorun'

class Object
  def blank?
    respond_to?(:empty?) ? empty? : !self
  end

  def present?
    !blank?
  end
end

module Rails
  def self.logger
    @logger ||= Logger.new(nil)
  end
end

class ExternalSync
  Row = Struct.new(:source, :source_id, :object, :o_id, keyword_init: true) do
    def update!(attrs)
      attrs.each { |k, v| self[k] = v }
    end
  end

  class << self
    attr_accessor :rows, :fail

    def find_by(**attrs)
      raise 'database unavailable' if fail

      rows.find { |r| attrs.all? { |k, v| r[k] == v } }
    end

    def create!(**attrs)
      Row.new(**attrs).tap { |r| rows << r }
    end
  end
end

class Ticket
  class << self
    attr_accessor :ids

    def exists?(id:)
      ids.include?(id)
    end
  end

  class Article
    Scope = Struct.new(:first_id) do
      def minimum(_column)
        first_id
      end
    end

    class << self
      attr_accessor :first_ids # ticket id => id of its first article

      def where(ticket_id:)
        Scope.new(first_ids[ticket_id])
      end
    end
  end
end

module Channel
  module Filter
  end
end

require_relative '../app/models/channel/filter/follow_up_thread_index'

class FollowUpThreadIndexTest < Minitest::Test
  Filter = Channel::Filter::FollowUpThreadIndex
  Ref    = Struct.new(:id)

  # Synthetic Thread-Index values in Outlook's layout: a 22-byte header
  # (reserved byte, start time, conversation GUID) for the original message,
  # one 5-byte block appended per reply, and an unrelated conversation.
  ORIGINAL = 'AQHcfk/FSOeeZc+ng/jAzjG0f2VIeQ=='.freeze
  REPLY    = 'AQHcfk/FSOeeZc+ng/jAzjG0f2VIeSSlgKWh'.freeze
  REPLY2   = 'AQHcfk/FSOeeZc+ng/jAzjG0f2VIeSSlgKWhySjdVIc='.freeze
  OTHER    = 'AQHcmaSQTAU21h+QkWJlDf88t6exig=='.freeze

  def setup
    ExternalSync.rows = []
    ExternalSync.fail = false
    Ticket.ids = [10, 20]
    Ticket::Article.first_ids = { 10 => 100, 20 => 200 }
  end

  def pre(mail)
    Filter.run({}, mail, {})
    mail
  end

  def post(mail, ticket_id, article_id)
    Filter.run({}, mail, Ref.new(ticket_id), Ref.new(article_id))
  end

  def key
    Filter.conversation_key(ORIGINAL)
  end

  def test_conversation_key_is_shared_by_replies
    assert_equal 44, key.size
    assert_equal key, Filter.conversation_key(REPLY)
    assert_equal key, Filter.conversation_key(REPLY2)
    refute_equal key, Filter.conversation_key(OTHER)
  end

  def test_conversation_key_ignores_folding_whitespace
    assert_equal key, Filter.conversation_key("#{ORIGINAL[0, 20]}\r\n #{ORIGINAL[20..]}")
  end

  def test_conversation_key_rejects_missing_or_short_values
    assert_nil Filter.conversation_key(nil)
    assert_nil Filter.conversation_key('')
    assert_nil Filter.conversation_key('AQID')
  end

  def test_thread_index_from_raw_reads_folded_header_only
    raw = "Subject: test\r\nthread-index:\r\n\t#{REPLY}\r\nMessage-ID: <x@y>\r\n\r\nThread-Index: #{OTHER}\r\n"
    assert_equal REPLY, Filter.thread_index_from_raw(raw)
    assert_nil Filter.thread_index_from_raw("Subject: none\r\n\r\nThread-Index: #{OTHER}\r\n")
    assert_nil Filter.thread_index_from_raw(nil)
  end

  def test_pre_filter_without_mapping_leaves_mail_alone
    assert_nil pre('thread-index': REPLY)[:'x-zammad-ticket-id']
  end

  def test_pre_filter_attaches_reply_to_mapped_ticket
    ExternalSync.create!(source: Filter::SOURCE, source_id: key, object: 'Ticket', o_id: 10)
    assert_equal 10, pre('thread-index': REPLY2)[:'x-zammad-ticket-id']
  end

  def test_pre_filter_keeps_zammads_own_match
    ExternalSync.create!(source: Filter::SOURCE, source_id: key, object: 'Ticket', o_id: 10)
    assert_equal 20, pre('thread-index': REPLY, 'x-zammad-ticket-id': 20)[:'x-zammad-ticket-id']
    assert_nil pre('thread-index': REPLY, 'x-zammad-ticket-number': '2026')[:'x-zammad-ticket-id']
  end

  def test_pre_filter_skips_deleted_ticket
    ExternalSync.create!(source: Filter::SOURCE, source_id: key, object: 'Ticket', o_id: 99)
    assert_nil pre('thread-index': REPLY)[:'x-zammad-ticket-id']
  end

  def test_pre_filter_errors_fall_back_to_new_ticket
    ExternalSync.fail = true
    assert_nil pre('thread-index': REPLY)[:'x-zammad-ticket-id']
  end

  def test_mail_without_thread_index_is_ignored
    assert_nil pre(subject: 'hi')[:'x-zammad-ticket-id']
    post({ subject: 'hi' }, 10, 100)
    assert_empty ExternalSync.rows
  end

  def test_post_filter_remembers_first_ticket
    post({ 'thread-index': ORIGINAL }, 10, 100)
    assert_equal [[key, 10]], ExternalSync.rows.map { |r| [r.source_id, r.o_id] }
  end

  def test_post_filter_keeps_mapping_when_mail_followed_up_elsewhere
    post({ 'thread-index': ORIGINAL }, 10, 100)
    post({ 'thread-index': REPLY }, 20, 201) # not ticket 20's first article
    assert_equal 10, ExternalSync.rows.first.o_id
  end

  def test_post_filter_moves_mapping_to_new_ticket
    post({ 'thread-index': ORIGINAL }, 10, 100)
    post({ 'thread-index': REPLY }, 20, 200) # opened ticket 20
    assert_equal 1, ExternalSync.rows.size
    assert_equal 20, ExternalSync.rows.first.o_id
  end
end
