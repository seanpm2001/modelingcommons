require 'test_helper'

class EmailRecommendationTest < ActiveSupport::TestCase
  should_belong_to :person
  should_belong_to :node
end
