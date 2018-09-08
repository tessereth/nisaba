# Nisaba

Have you ever found yourself making the same comments over and over on pull requests?
Or you wish you had labels to mark what kind of changes were in a PR but it's too tedious to add them?
Then you're in the right place!

Nisaba is a gem that lets you write custom rules for adding labels, comments and reviews to pull requests simply and easily.
For example, to add the `migration` label if a PR has any database migrations (and remove it if they get removed), just run:

```ruby
require 'nisaba'

Nisaba.configure do |n|
  n.app_id = ENV['GITHUB_APP_IDENTIFIER']
  n.app_private_key = ENV['GITHUB_PRIVATE_KEY']
  n.webhook_secret = ENV['GITHUB_WEBHOOK_SECRET']

  n.label 'migration' do |context|
    context.file?(%r{db/migrate/.*})
  end
end

Nisaba.run!
```

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'nisaba'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install nisaba

## Usage

To use Nisaba, you will to:
 
1. Set up [ngrok](https://ngrok.com/) or [smee](https://smee.io/) or similar so github can send messages to your local machine
2. [Create a github app](https://developer.github.com/apps/building-github-apps/creating-a-github-app/):
    * Webhook URL should have `/webhook` as the path (eg `http://aabbccdd.ngrok.io/webhook`)
    * Webhook secret is required
    * Enable pull request read/write permissions
    * Subscribe to pull request events
    * Install it in the repos you wish to manage
3. Create your ruby script. Check out [the example](https://github.com/tessereth/nisaba-example) for somewhere to start.

Full API documentation coming soon!

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/tessereth/nisaba.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
