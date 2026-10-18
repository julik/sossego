# frozen_string_literal: true

require "test_helper"

class Sossego::TurboStreamTest < ActiveSupport::TestCase
  BUILT_IN = %i[append prepend replace update remove before after refresh]

  setup do
    Sossego::Event.delete_all
    @stream = Sossego::Stream.new("board:1:updates")
    @counter = Counter.create!(name: "Calm", value: 3)
  end

  def element(html)
    fragment = Nokogiri::HTML5.fragment(html)
    assert_equal 1, fragment.children.length, "expected one element in #{html}"
    node = fragment.children.first
    template = node.at_css("template")
    {name: node.name, attributes: node.attributes.transform_values(&:value), template: template&.inner_html}
  end

  def turbo_rails(action, **options)
    ApplicationController.helpers.turbo_stream_action_tag(action, **options)
  end

  test "builds the same element as turbo-rails for every built-in action" do
    BUILT_IN.each do |action|
      ours = Sossego::TurboStream.tag(action, target: "counters", template: "<p>hi</p>", "request-id": nil)
      theirs = turbo_rails(action, target: "counters", template: "<p>hi</p>")
      assert_equal element(theirs), element(ours), action
    end
  end

  test "turns a record into its dom id, and into a selector for targets" do
    assert_equal({"action" => "remove", "target" => "counter_#{@counter.id}"}, element(Sossego::TurboStream.tag(:remove, target: @counter))[:attributes])
    assert_equal({"action" => "remove", "targets" => "#counter_#{@counter.id}"}, element(Sossego::TurboStream.tag(:remove, targets: @counter))[:attributes])
    assert_equal "special_counter_#{@counter.id}", element(Sossego::TurboStream.tag(:remove, target: [@counter, :special]))[:attributes]["target"]
    assert_equal ".counter", element(Sossego::TurboStream.tag(:remove, targets: ".counter"))[:attributes]["targets"]
  end

  test "leaves the template out of remove and refresh, and puts an empty one in the others" do
    assert_nil element(Sossego::TurboStream.tag(:remove, target: "x"))[:template]
    assert_nil element(Sossego::TurboStream.tag(:refresh))[:template]
    assert_equal "", element(Sossego::TurboStream.tag(:append, target: "x"))[:template]
  end

  test "takes a custom action with attributes of its own, escaped" do
    html = Sossego::TurboStream.render(:set_title, attributes: {title: %(3 "new" <messages>), "data-sound": "ping"})

    assert_equal({"action" => "set_title", "title" => %(3 "new" <messages>), "data-sound" => "ping"}, element(html)[:attributes])
    assert_equal "", element(html)[:template]
  end

  test "passes method: morph through for replace and update" do
    assert_equal "morph", element(Sossego::TurboStream.render(:replace, target: @counter, html: "<div></div>", attributes: {method: :morph}))[:attributes]["method"]
  end

  test "renders a partial with the configured renderer" do
    html = Sossego::TurboStream.render(:replace, target: @counter, partial: "board/counter", locals: {counter: @counter})
    template = element(html)[:template]

    assert_includes template, %(id="counter_#{@counter.id}")
    assert_includes template, ">3<"
  end

  test "takes html: and content: as they are, and render: false for no template" do
    assert_equal "<b>1</b>", element(Sossego::TurboStream.render(:update, target: "x", html: "<b>1</b>"))[:template]
    assert_equal "<b>2</b>", element(Sossego::TurboStream.render(:update, target: "x", content: "<b>2</b>"))[:template]
    assert_equal "", element(Sossego::TurboStream.render(:update, target: "x", render: false))[:template]
  end

  test "a refresh carries the request id when turbo-rails knows one" do
    Turbo.stub(:current_request_id, "req-123") do
      assert_equal "req-123", element(Sossego::TurboStream.tag(:refresh))[:attributes]["request-id"]
    end
    assert_nil element(Sossego::TurboStream.tag(:refresh))[:attributes]["request-id"]
  end

  test "Stream#publish_turbo_stream publishes the element as text under turbo_stream" do
    event = @stream.publish_turbo_stream(:append, target: "counters", partial: "board/counter", locals: {counter: @counter})

    assert_equal ["turbo_stream", "text"], [event.event_name, event.fmt]
    assert_equal({"action" => "append", "target" => "counters"}, element(event.value)[:attributes])
  end

  test "Stream#publish_turbo_stream joins ready-made elements into one event" do
    a = Sossego::TurboStream.tag(:remove, target: "a")
    b = Sossego::TurboStream.tag(:remove, target: "b")

    event = @stream.publish_turbo_stream(a, b)

    assert_equal a + b, event.value
    assert_equal 1, Sossego::Event.for_stream(@stream.id).count
  end

  test "refuses to mix ready-made elements with options, or two actions" do
    assert_raises(ArgumentError) { @stream.publish_turbo_stream("<turbo-stream action=\"remove\" target=\"a\"></turbo-stream>", target: "b") }
    assert_raises(ArgumentError) { @stream.publish_turbo_stream(:append, :remove, target: "b") }
    assert_raises(ArgumentError) { @stream.publish_turbo_stream }
  end
end
