# frozen_string_literal: true

module Sossego
  # Builds `<turbo-stream>` elements to publish on a stream, the way
  # turbo-rails' `turbo_stream_action_tag` and `broadcast_action_to` do, so
  # any Turbo Stream action works: the built-in ones (`append`, `prepend`,
  # `replace`, `update`, `remove`, `before`, `after`, `refresh`, and `replace`
  # or `update` with `method: "morph"`) and custom ones registered in the
  # browser with `Turbo.StreamActions`. turbo-rails is not needed on the server.
  #
  # The `turbo_stream` handler of `@julik/sossego-stimulus` hands the HTML to
  # `Turbo.renderStreamMessage`.
  #
  # @example
  #   stream.publish_turbo_stream(:append, target: "comments", partial: "comments/comment", locals: {comment:})
  #   stream.publish_turbo_stream(:replace, target: comment, html: "<div id='comment_1'>…</div>", attributes: {method: :morph})
  #   stream.publish_turbo_stream(:remove, target: comment)
  #   stream.publish_turbo_stream(:refresh)
  #   stream.publish_turbo_stream(:set_title, attributes: {title: "3 new"})       # a custom action
  #   stream.publish_turbo_stream(Sossego::TurboStream.tag(:remove, target: "a"),  # several in one event
  #                               Sossego::TurboStream.tag(:remove, target: "b"))
  module TurboStream
    # Actions whose element carries no `<template>`
    WITHOUT_TEMPLATE = %w[remove refresh].freeze

    module_function

    # The HTML to publish: elements given as strings, joined, or one element
    # built from an action and its options ({.render}).
    #
    # @return [String]
    def html_for(*args, **options)
      if args.any? && args.all? { |arg| arg.is_a?(String) && arg.lstrip.start_with?("<") }
        raise ArgumentError, "options are for an action, not for ready-made <turbo-stream> elements" if options.any?
        args.join
      elsif args.length == 1
        render(args.first, **options)
      else
        raise ArgumentError, "pass one action, or one or more <turbo-stream> elements as strings"
      end
    end

    # One `<turbo-stream>` element, its template rendered the way turbo-rails'
    # broadcasts render theirs.
    #
    # @param action [String, Symbol] any Turbo Stream action, custom ones too
    # @param target [String, ActiveRecord::Base, Array, nil] an element id, or
    #   what `dom_id` takes
    # @param targets [String, ActiveRecord::Base, Array, nil] a CSS selector, or
    #   what `dom_id` takes (as `#dom_id`)
    # @param attributes [Hash] more attributes on the element, e.g.
    #   `{method: :morph}` or a custom action's own
    # @param rendering [Hash] the template: `content:` or `html:` (a string, as
    #   it is), `render: false` (none), or options for the renderer
    #   (`partial:`, `locals:`, `template:`, `renderable:`...)
    # @return [String]
    def render(action, target: nil, targets: nil, attributes: {}, **rendering)
      tag(action, target: target, targets: targets, template: template_for(rendering), **attributes)
    end

    # One `<turbo-stream>` element around a template you already have. Like
    # turbo-rails' `turbo_stream_action_tag`.
    #
    # @return [String]
    def tag(action, target: nil, targets: nil, template: nil, **attributes)
      action = action.to_s
      if action == "refresh" && !attributes.key?(:"request-id") && !attributes.key?("request-id")
        attributes = attributes.merge("request-id": current_request_id)
      end

      element = {action: action}
      if (id = dom_target(target))
        element[:target] = id
      elsif (selector = dom_target(targets, selector: true))
        element[:targets] = selector
      end
      element.merge!(attributes)

      html_attributes = element.filter_map do |name, value|
        next if value.nil? || value == false
        %(#{name}="#{ERB::Util.html_escape(value)}")
      end
      inner = WITHOUT_TEMPLATE.include?(action) ? "" : "<template>#{template}</template>"
      "<turbo-stream #{html_attributes.join(" ")}>#{inner}</turbo-stream>"
    end

    # @api private
    def template_for(rendering)
      rendering = rendering.dup
      content = rendering.delete(:content)
      html = rendering.delete(:html)
      return nil if rendering.delete(:render) == false

      content || html || (Sossego.turbo_stream_renderer.call.render(formats: [:html], **rendering) if rendering.any?)
    end

    # @api private
    def dom_target(target, selector: false)
      parts = Array.wrap(target)
      if parts.any? { |part| part.respond_to?(:to_key) || part.is_a?(Class) }
        "#{"#" if selector}#{ActionView::RecordIdentifier.dom_id(*parts)}"
      else
        target
      end
    end

    # The request that caused a refresh, so the tab that made it can skip it
    # (turbo-rails sets it for each request).
    #
    # @api private
    def current_request_id
      Turbo.current_request_id if defined?(Turbo) && Turbo.respond_to?(:current_request_id)
    end
  end
end
