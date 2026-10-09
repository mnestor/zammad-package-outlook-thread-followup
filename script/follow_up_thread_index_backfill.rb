# Records Outlook conversation -> ticket mappings for mail that arrived
# before Channel::Filter::FollowUpThreadIndex was installed, and lists
# conversations already split across tickets so agents can merge them.
# A split conversation maps to its oldest ticket.
#
# Run inside a Zammad Rails container:
#
#   bundle exec rails r script/follow_up_thread_index_backfill.rb                  # dry run
#   APPLY=1 DAYS=365 bundle exec rails r script/follow_up_thread_index_backfill.rb # write mappings

filter = Channel::Filter::FollowUpThreadIndex
apply  = ENV['APPLY'] == '1'
days   = Integer(ENV.fetch('DAYS', '365'))

email   = Ticket::Article::Type.lookup(name: 'email')
scanned = 0

# conversation key => ticket ids, oldest first (find_each walks ids in order)
tickets_by_key = Hash.new { |hash, key| hash[key] = [] }

Ticket::Article.where(type_id: email.id).where('created_at > ?', days.days.ago).find_each do |article|
  scanned += 1
  puts "  scanned #{scanned} articles..." if (scanned % 500).zero?

  key = filter.conversation_key(filter.thread_index_from_raw(article.as_raw&.content))
  next if key.nil?

  ids = tickets_by_key[key]
  ids << article.ticket_id if ids.exclude?(article.ticket_id)
end

created  = 0
existing = 0
tickets_by_key.each do |key, ticket_ids|
  if ExternalSync.exists?(source: filter::SOURCE, source_id: key)
    existing += 1
    next
  end

  created += 1
  next if !apply

  ExternalSync.create!(source: filter::SOURCE, source_id: key, object: 'Ticket', o_id: ticket_ids.first)
end

splits = tickets_by_key.values.select { |ids| ids.size > 1 }

puts "Scanned #{scanned} email articles from the last #{days} days."
puts "Found #{tickets_by_key.size} Outlook conversations: #{existing} already mapped, #{created} #{apply ? 'mapped now' : 'to map (dry run, set APPLY=1)'}."
puts "#{splits.size} conversations are split across tickets (oldest first, the mapping points at the first):"
splits.each do |ids|
  puts '  ' + Ticket.where(id: ids).order(:id).map { |t| "##{t.number} [#{t.state.name}] #{t.title}" }.join('  |  ')
end
