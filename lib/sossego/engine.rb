# frozen_string_literal: true

module Sossego
  class Engine < ::Rails::Engine
    isolate_namespace Sossego

    # The JS client ships in app/javascript. Propshaft (or Sprockets) serves
    # it from there, and importmap-rails gets the pins in config/importmap.rb.
    initializer "sossego.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/javascript")
      end
    end

    initializer "sossego.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << root.join("config/importmap.rb")
        app.config.importmap.cache_sweepers << root.join("app/javascript")
      end
    end

    initializer "sossego.helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        helper Sossego::StreamsHelper
      end
    end
  end
end
