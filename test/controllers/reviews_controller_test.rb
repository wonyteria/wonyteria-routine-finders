require "test_helper"

class ReviewsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @host = users(:host)
    @participant = users(:participant)
    @challenge = challenges(:free_challenge)
    @participation = participants(:participant_in_free)
  end

  def login_as(user)
    post login_path, params: { email: user.email, password: "password123" }
  end

  test "should get index without authentication" do
    get challenge_reviews_path(@challenge)
    assert_response :success
  end

  test "should display average rating" do
    Review.create!(challenge: @challenge, user: @host, rating: 5)
    get challenge_reviews_path(@challenge)
    assert_response :success
  end

  test "should redirect new to login when not authenticated" do
    get new_challenge_review_path(@challenge)
    assert_redirected_to prototype_login_path
  end

  test "should get new when authenticated as participant" do
    login_as(@participant)
    @participation.update!(joined_at: 8.days.ago)
    get new_challenge_review_path(@challenge)
    assert_response :success
  end

  test "should create review with valid params" do
    login_as(@participant)
    @participation.update!(joined_at: 8.days.ago)

    assert_difference("Review.count", 1) do
      post challenge_reviews_path(@challenge), params: {
        review: {
          rating: 5,
          content: "Great challenge!"
        }
      }
    end

    assert_redirected_to challenge_path(@challenge, tab: "community")
  end

  test "should not create review with invalid params" do
    login_as(@participant)
    @participation.update!(joined_at: 8.days.ago)

    assert_no_difference("Review.count") do
      post challenge_reviews_path(@challenge), params: {
        review: {
          rating: nil,
          content: "Missing rating"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "should redirect to challenge if already reviewed" do
    login_as(@participant)
    Review.create!(challenge: @challenge, user: @participant, rating: 4)

    get new_challenge_review_path(@challenge)
    assert_redirected_to challenge_path(@challenge)
  end

  test "should update own review" do
    login_as(@participant)
    review = Review.create!(challenge: @challenge, user: @participant, rating: 3)

    patch challenge_review_path(@challenge, review), params: {
      review: { rating: 5, content: "Updated review" }
    }

    assert_redirected_to challenge_path(@challenge)
    review.reload
    assert_equal 5, review.rating
    assert_equal "Updated review", review.content
  end

  test "should delete own review" do
    login_as(@participant)
    review = Review.create!(challenge: @challenge, user: @participant, rating: 3)

    assert_difference("Review.count", -1) do
      delete challenge_review_path(@challenge, review)
    end

    assert_redirected_to challenge_path(@challenge)
  end

  test "should not update other users review" do
    login_as(@participant)
    review = Review.create!(challenge: @challenge, user: @host, rating: 3)

    patch challenge_review_path(@challenge, review), params: {
      review: { rating: 1 }
    }

    assert_redirected_to challenge_path(@challenge)
    review.reload
    assert_equal 3, review.rating
  end
end
