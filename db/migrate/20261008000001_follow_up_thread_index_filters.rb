# Registers Channel::Filter::FollowUpThreadIndex before and after ticket
# creation. The pre filter's name sorts right after Zammad's own
# 0007_postmaster_filter_follow_up_check and before the merged-ticket (0008)
# and closed-ticket (0200) checks, so those still apply to its matches.
class FollowUpThreadIndexFilters < ActiveRecord::Migration[6.1]
  NAMES = %w[
    0007_postmaster_filter_follow_up_thread_index
    5402_postmaster_filter_follow_up_thread_index
  ].freeze

  def up
    Setting.create_if_not_exists(
      title:       'Defines postmaster filter.',
      name:        NAMES[0],
      area:        'Postmaster::PreFilter',
      description: 'Defines postmaster filter to identify follow-ups by Outlook conversation (Thread-Index).',
      options:     {},
      state:       'Channel::Filter::FollowUpThreadIndex',
      frontend:    false
    )

    Setting.create_if_not_exists(
      title:       'Defines postmaster filter.',
      name:        NAMES[1],
      area:        'Postmaster::PostFilter',
      description: 'Defines postmaster filter to remember the ticket of each Outlook conversation (Thread-Index).',
      options:     {},
      state:       'Channel::Filter::FollowUpThreadIndex',
      frontend:    false
    )
  end

  def down
    Setting.where(name: NAMES).destroy_all
  end
end
