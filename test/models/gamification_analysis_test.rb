require "test_helper"

class GamificationAnalysisTest < ActiveSupport::TestCase
  test "analyze_user_data_for_gamification" do
    out = []
    users = User.all.to_a

    out << "========================================"
    out << "GAMIFICATION DATA ANALYSIS"
    out << "Total Platform Users: #{users.size}"

    months_to_check = [2.months.ago, 1.month.ago, Time.current]

    months_to_check.each do |time|
      date = time.to_date
      out << "=== Analysis for #{date.strftime('%Y-%m')} ==="
      
      stats = users.map do |user|
        start_date = date.beginning_of_month
        end_date = [date.end_of_month, Date.current].min
        
        routine_count = PersonalRoutineCompletion.joins(:personal_routine)
                          .where(personal_routines: { user_id: user.id })
                          .where(completed_on: start_date..end_date)
                          .count
                          
        challenge_count = VerificationLog.joins(:participant)
                            .where(participants: { user_id: user.id })
                            .where(created_at: start_date.beginning_of_day..end_date.end_of_day)
                            .count
        
        log_rate = user.monthly_routine_log_rate(date)
        ach_rate = user.monthly_achievement_rate(date)
        score = user.rufa_club_score(date)
        
        {
          id: user.id,
          routines: routine_count,
          challenges: challenge_count,
          log_rate: log_rate.to_f.round(1),
          ach_rate: ach_rate.to_f.round(1),
          score: score.to_f.round(1)
        }
      end
      
      assert_equal users.size, stats.size
      assert stats.all? { |s| [:log_rate, :ach_rate, :score].all? { |key| s[key].finite? && s[key] >= 0 } }
      valid_stats = stats.select { |s| s[:routines] > 0 || s[:challenges] > 0 }
      
      if valid_stats.empty?
        out << "No activity data for this month."
        next
      end
      
      avg_routines = valid_stats.sum { |s| s[:routines] }.fdiv(valid_stats.size)
      out << "Tot: #{valid_stats.size}, AvgR: #{avg_routines.round(1)}"
      scores = valid_stats.map { |s| s[:score] }.sort
      out << "Scores P50: #{scores[(scores.size * 0.5).to_i]}, P90: #{scores[(scores.size * 0.9).to_i]}"
      out << valid_stats.sort_by { |s| -s[:score] }.first(5).map { |s| "U#{s[:id]}:R#{s[:routines]}:S#{s[:score]}" }.join(", ")
    end
    Rails.logger.error "\n\n=== GAMIFICATION REPORT ===\n#{out.join("\n")}\n=========================\n"
    assert true
  end
end
