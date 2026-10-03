package slack

import (
	"strconv"
	"strings"
)

// CompareTS orders Slack timestamps ("seconds.micros"). An empty ts sorts first.
func CompareTS(a, b string) int {
	if a == b {
		return 0
	}
	if a == "" {
		return -1
	}
	if b == "" {
		return 1
	}
	as, af, _ := strings.Cut(a, ".")
	bs, bf, _ := strings.Cut(b, ".")
	ai, _ := strconv.ParseInt(as, 10, 64)
	bi, _ := strconv.ParseInt(bs, 10, 64)
	if ai != bi {
		if ai < bi {
			return -1
		}
		return 1
	}
	af = (af + "000000")[:6]
	bf = (bf + "000000")[:6]
	return strings.Compare(af, bf)
}
