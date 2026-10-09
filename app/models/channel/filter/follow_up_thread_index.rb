# Attaches incoming mail to the ticket of its Outlook conversation when
# Zammad's own follow-up detection finds nothing.
#
# Mail reaches Zammad through an Exchange inbox-rule redirect, which gives
# every message a new Message-ID, so In-Reply-To/References never match a
# stored article. Outlook's Thread-Index header survives the redirect: its
# first 22 bytes (reserved byte, start time, conversation GUID) are the same
# on every message of a conversation, and each reply appends 5 more bytes.
#
# Runs as a pre filter (look the conversation up, set x-zammad-ticket-id) and
# as a post filter (remember which ticket the conversation landed in), the
# same shape as Channel::Filter::BaseExternalCheck. Mappings live in
# ExternalSync, so Zammad moves them when tickets are merged and drops them
# when a ticket is deleted.
module Channel::Filter::FollowUpThreadIndex
  SOURCE             = 'OutlookThreadIndex'.freeze
  CONVERSATION_BYTES = 22

  def self.run(_channel, mail, ticket_or_transaction_params = nil, article = nil, _session_user = nil)
    key = conversation_key(mail[:'thread-index'])
    return if key.blank?

    if ticket_or_transaction_params.blank? || ticket_or_transaction_params.is_a?(Hash)
      follow_up(mail, key)
    else
      remember(key, ticket_or_transaction_params, article)
    end
  end

  # Pre filter. Errors are logged rather than raised: a failing pre filter
  # stops the mail from being processed at all, and a new ticket is the
  # better outcome.
  def self.follow_up(mail, key)
    return if mail[:'x-zammad-ticket-id'].present? || mail[:'x-zammad-ticket-number'].present?

    sync = find_sync(key)
    return if sync.blank?
    return if !Ticket.exists?(id: sync.o_id)

    Rails.logger.debug { "Follow-up for ticket id #{sync.o_id} by Thread-Index conversation #{key}." }
    mail[:'x-zammad-ticket-id'] = sync.o_id
  rescue => e
    Rails.logger.error "Thread-Index follow-up lookup failed for conversation #{key}: #{e.inspect}"
  end

  # Post filter. The first ticket of a conversation keeps it; a later mail
  # only moves the conversation when it opened a new ticket, which means
  # Zammad declined the follow-up (e.g. the group opens new tickets for
  # replies to closed ones), so later replies belong with the new ticket.
  def self.remember(key, ticket, article)
    sync = find_sync(key)
    if sync.blank?
      ExternalSync.create!(source: SOURCE, source_id: key, object: 'Ticket', o_id: ticket.id)
      return
    end
    return if sync.o_id == ticket.id
    return if !first_article?(ticket, article)

    sync.update!(o_id: ticket.id)
  end

  def self.find_sync(key)
    ExternalSync.find_by(source: SOURCE, source_id: key, object: 'Ticket')
  end

  def self.first_article?(ticket, article)
    article.present? && Ticket::Article.where(ticket_id: ticket.id).minimum(:id) == article.id
  end

  # Returns the conversation part of a Thread-Index header as hex, or nil if
  # the header is missing or too short to carry one.
  def self.conversation_key(thread_index)
    raw = Base64.decode64(thread_index.to_s.delete(" \t\r\n"))
    return if raw.bytesize < CONVERSATION_BYTES

    raw.byteslice(0, CONVERSATION_BYTES).unpack1('H*')
  end

  # Returns the Thread-Index header value from a raw RFC 822 message, for
  # mail that is already stored (see script/follow_up_thread_index_backfill.rb).
  def self.thread_index_from_raw(raw)
    head = raw.to_s.b.split(%r{\r?\n\r?\n}, 2).first.to_s.gsub(%r{\r?\n[ \t]+}, ' ')
    head[%r{^thread-index:[ \t]*(\S+)}i, 1]
  end
end
