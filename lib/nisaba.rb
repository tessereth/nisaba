# frozen_string_literal: true

require 'nisaba/application'
require 'nisaba/configuration'
require 'nisaba/errors'
require 'nisaba/handler/base'
require 'nisaba/handler/comment'
require 'nisaba/handler/label'
require 'nisaba/handler/review'
require 'nisaba/request_context'
require 'nisaba/version'

module Nisaba
  extend self
  extend Forwardable

  def_delegators :'Nisaba::Application', :configure, :run!
end
