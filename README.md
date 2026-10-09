# zammad-addon

A Zammad postmaster filter that attaches Outlook/Exchange replies to their
existing ticket by `Thread-Index` when a mailbox redirect has rewritten their
Message-IDs.

The files are plain Ruby, bind-mounted into the official Zammad Docker
containers. Zammad's `.zpm` packages don't fit Docker: the image's entrypoint
never reinstalls them, so their files vanish whenever a container is
recreated. Tested with Zammad 7.2.

## The problem

Zammad matches replies to tickets by Message-ID (`References`/`In-Reply-To`).
When mail reaches Zammad through an Exchange inbox-rule redirect, for example a
shared mailbox with a rule that redirects everything to Zammad's address,
Exchange gives every redirected message a new Message-ID. Replies reference the
original IDs, which Zammad never saw, so each reply opens a new ticket.

Redirected mail shows it in the raw headers: `Resent-From` names the
redirecting mailbox and `X-MS-Exchange-Inbox-Rules-Loop` is set.

Outlook's `Thread-Index` header survives the redirect: its first 22 bytes
identify the conversation on every message in it.

## How it works

[`Channel::Filter::FollowUpThreadIndex`](app/models/channel/filter/follow_up_thread_index.rb)
runs inside Zammad's mail processing, so the reply is attached before any
ticket (and auto-reply) is created:

- **Pre filter**, right after Zammad's own follow-up check: if nothing matched
  yet, look up the conversation and set `x-zammad-ticket-id`. Zammad's
  merged-ticket and closed-ticket (group "follow-up possible") checks still run
  afterwards. A lookup error is logged and the mail opens a new ticket as
  before, rather than blocking mail processing.
- **Post filter**: record conversation -> ticket in `external_syncs` (source
  `OutlookThreadIndex`) for the first ticket of each conversation. If a
  conversation later opens a new ticket (e.g. a reply to a closed ticket in a
  group set to open new ones), the mapping moves to the new ticket. Zammad
  moves mappings on merge and deletes them with their ticket.

Mail without a `Thread-Index` (anything not from Outlook/Exchange) is not
touched. Anyone who has a message from a conversation can send mail into its
ticket. That is the same trust Zammad already gives `References` matching.

Outlook starts a new conversation, with a new `Thread-Index`, when someone
edits the subject of a reply. Those replies still open a new ticket.

## Install

1. Put this repository in a directory named `zammad-addon` next to Zammad's
   `docker-compose.yml`, and copy `docker-compose.override.yml` beside
   `docker-compose.yml`. The override's paths assume both. Compose picks the
   override up automatically. If you already have an override file, merge the
   volumes into it. Adjust the service names if yours differ from the official
   `zammad-docker-compose` ones.
   ```sh
   git clone <this repository> zammad-addon
   cp zammad-addon/docker-compose.override.yml .
   ```
2. `docker compose up -d`. `zammad-init` runs the
   [migration](db/migrate/20261008000001_follow_up_thread_index_filters.rb)
   that registers the two filters. Check it with:
   ```sh
   docker compose exec zammad-railsserver bundle exec rails r \
     "p Setting.where('name LIKE ?', '%follow_up_thread_index').pluck(:name, :area)"
   ```
   Expect the `Postmaster::PreFilter` and `Postmaster::PostFilter` entries.
3. Backfill conversations that started before the install. Until a
   conversation is mapped, its replies still open new tickets. The
   [backfill](script/follow_up_thread_index_backfill.rb) only writes
   conversation -> ticket mappings to `external_syncs`; it doesn't change any
   ticket. Its dry run also lists conversations already split across tickets,
   which agents can merge by hand:
   ```sh
   docker compose exec zammad-railsserver bundle exec rails r script/follow_up_thread_index_backfill.rb
   docker compose exec -e APPLY=1 zammad-railsserver bundle exec rails r script/follow_up_thread_index_backfill.rb
   ```
   `DAYS` (default 365) limits how far back it reads. Once a closed ticket's
   conversation is mapped, a late reply reopens that ticket, as it would with a
   `References` match, unless the group is set to open a new ticket instead.

## Remove

Unregister the filters **before** removing the mounts. A registered filter
whose file is gone stops all mail processing:

```sh
docker compose exec zammad-railsserver bundle exec rake db:migrate:down VERSION=20261008000001
```

Then delete the override file and `docker compose up -d`. Mappings stay in
`external_syncs` (harmless). Delete them with
`ExternalSync.where(source: 'OutlookThreadIndex').delete_all` if wanted.

## Test

```sh
ruby test/follow_up_thread_index_test.rb
```

Needs only Ruby (minitest ships with it). Runs the filter against stand-ins
for the Rails/Zammad classes it uses, with synthetic `Thread-Index` values in
Outlook's format.
