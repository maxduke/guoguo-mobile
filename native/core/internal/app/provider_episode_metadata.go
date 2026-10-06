package app

import (
	"fmt"
	"strconv"
	"strings"
)

func followingEpisodeCount(drama Drama) int {
	for _, value := range []any{drama.TotalEpisode, drama.TotalEpisodeSnake, drama.ChapterCount, drama.ChapterCountSnake, drama.EpisodeCount, drama.EpisodeCountSnake, drama.Total, drama.Episodes} {
		count, err := strconv.Atoi(strings.TrimSpace(fmt.Sprint(value)))
		if err == nil && count > 0 && count <= 10000 {
			return count
		}
	}
	return 0
}
