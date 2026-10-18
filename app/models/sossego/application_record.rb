# frozen_string_literal: true

module Sossego
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    connects_to(**Sossego.connects_to) if Sossego.connects_to
  end
end
