require "test_helper"

class ChallengeCreationTest < ActiveSupport::TestCase
  test "process params and create successfully" do
    user = User.first || User.create!(email: 'test@example.com', password: 'password', nickname: 'tester')
    
    raw_params = {
      title: "Test Challenge with JSON Arrays",
      start_date: (Date.current + 7.days).to_s,
      end_date: (Date.current + 21.days).to_s,
      recruitment_start_date: Date.current.to_s,
      recruitment_end_date: (Date.current + 6.days).to_s,
      cost_type: "free",
      admission_type: "first_come",
      max_participants: 10,
      daily_goals: JSON.generate({ "mon" => ["Drink water"] }),
      days: JSON.generate(["mon", "tue"]),
      reward_policy: JSON.generate([{"rank" => "1", "reward" => "prize"}]),
      certification_goal: "Be healthy",
      application_questions: JSON.generate(["Why join?"])
    }

    controller = ChallengesController.new
    controller.request = ActionDispatch::Request.new({})
    controller.params = ActionController::Parameters.new(challenge: raw_params)

    params_hash = controller.send(:challenge_params).to_h
    raw = controller.params[:challenge]
    [ :days, :daily_goals, :reward_policy, :application_questions ].each do |attr|
      if raw && raw[attr].is_a?(String) && raw[attr].present?
        begin
          parsed_val = JSON.parse(raw[attr])
          if attr == :days && parsed_val.is_a?(Array)
            parsed_val = parsed_val.map(&:to_s)
          end
          params_hash[attr.to_s] = parsed_val
        rescue JSON::ParserError
          params_hash[attr.to_s] = raw[attr]
        end
      end
    end

    challenge = Challenge.new(params_hash)
    challenge.host = user

    assert challenge.save, "Challenge validation failed: #{challenge.errors.full_messages}"
    assert_equal ["mon", "tue"], challenge.days
    assert_equal({"mon"=>["Drink water"]}, challenge.daily_goals)
    assert_equal [{"rank"=>"1", "reward"=>"prize"}], challenge.reward_policy
    assert_equal "Be healthy", challenge.certification_goal
    assert_equal ["Why join?"], challenge.application_questions
  end
end
