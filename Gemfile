# frozen_string_literal: true

source 'https://rubygems.org'

gem 'ostruct'
gem 'drb'
gem 'rake', '~> 13.0'
gem 'rspec', '~> 3.13'
gem 'rubocop', '~> 1.70', require: false
gem 'yard', '~> 0.9', require: false
gem 'kramdown', '~> 2.4', require: false

# Only so the WebUI page specs can load Lich's own lib/api/webui.rb under
# bundler: window_presentation.rb requires fiddle, which is a bundled gem
# from Ruby 3.5 and so is invisible inside a bundle that does not name it.
# Lich itself runs without bundler and is unaffected.
gem 'fiddle', require: false
