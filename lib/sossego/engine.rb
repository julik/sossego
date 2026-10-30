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

    # Assiette serves the packages as "@julik/sossego-<part>/index.js" and
    # fingerprints the imports between them. Every Assiette::Server runs this
    # on its handler; without assiette it never runs. Added next to whatever
    # another gem exposed under "@julik", since the scope is shared.
    initializer "sossego.assiette" do
      ActiveSupport.on_load(:assiette) do
        expose(JavaScript::SCOPE, Array(exposed[JavaScript::SCOPE]) | [Sossego.javascript.root.join(JavaScript::SCOPE)])
      end
    end

    initializer "sossego.helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        helper Sossego::StreamsHelper
        helper Sossego::ImportmapHelper
      end
    end
  end
end
