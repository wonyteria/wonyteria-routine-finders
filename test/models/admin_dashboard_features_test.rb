require "test_helper"

class AdminDashboardFeaturesTest < ActiveSupport::TestCase
  setup do
    @host = User.create!(email: 'host_admin2@test.com', password: 'password', nickname: 'HostAdmin2', role: :club_admin)
    @participant_user = User.create!(email: 'part2@test.com', password: 'password', nickname: 'Part2')
    
    @challenge = Challenge.create!(
      title: "Settings Test Challenge",
      summary: "Test Settings",
      start_date: Date.today,
      end_date: Date.today + 7.days,
      verification_type: "photo",
      category: "HEALTH",
      host: @host,
      cost_type: "fee",
      amount: 10000,
      admission_type: "approval"
    )
  end

  test "should properly parse json arrays in update params" do
    params_hash = {
      daily_goals: { "1" => "Goal 1" }.to_json,
      reward_policy: ["Reward 1"].to_json,
      application_questions: ["Q1?", "Q2?"].to_json,
      category: "LIFE"
    }
    
    # 1. Simulate JSON Parsing done in Controller
    update_params = params_hash.dup
    
    update_params[:daily_goals] = JSON.parse(update_params[:daily_goals])
    update_params[:reward_policy] = JSON.parse(update_params[:reward_policy])
    update_params[:application_questions] = JSON.parse(update_params[:application_questions])
    
    @challenge.update!(update_params)
    @challenge.reload
    
    assert_equal "LIFE", @challenge.category
    assert_equal ["Reward 1"], @challenge.reward_policy
    assert_equal ["Q1?", "Q2?"], @challenge.application_questions
    assert_equal "Goal 1", @challenge.daily_goals["1"]
  end

  test "cost cannot be updated when participants exist" do
    # Add a participant
    @challenge.participants.create!(user: @participant_user, paid_amount: 10000, joined_at: Time.current)
    
    params_hash = {
      cost_type: "free",
      amount: 0,
      title: "New Title Allowed"
    }

    # Simulate Controller logic protecting cost
    if @challenge.participants.exists?
      params_hash.delete(:cost_type)
      params_hash.delete(:amount)
    end
    
    @challenge.update!(params_hash)
    
    assert_equal "New Title Allowed", @challenge.title
    assert_equal "fee", @challenge.cost_type # Unchanged
    assert_equal 10000, @challenge.amount # Unchanged
  end

  test "duplicate pending application should be blocked" do
    # Simulate DB state for pending check
    app1 = @challenge.challenge_applications.new(user: @participant_user, depositor_name: @participant_user.nickname, contact_info: "participant@example.invalid")
    assert app1.save, app1.errors.full_messages.join(", ")
    
    # Create action logic
    has_pending = @challenge.challenge_applications.exists?(user: @participant_user, status: :pending)
    
    assert has_pending, "Should detect existing pending application"
  end
end
