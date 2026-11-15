require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  test "offline guide is explicitly public and identical for signed-out and signed-in users" do
    get pwa_offline_path
    assert_response :success
    assert_includes response.headers["Cache-Control"], "public"
    anonymous_guide = response.body

    post login_path, params: { email: users(:participant).email, password: "password123" }
    assert_redirected_to prototype_home_path
    get profile_path
    assert_response :success
    get pwa_offline_path
    assert_response :success
    assert_equal anonymous_guide, response.body
    assert_includes response.headers["Cache-Control"], "public"
  end
end
