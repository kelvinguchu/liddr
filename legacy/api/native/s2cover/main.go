package main

import (
	"bufio"
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/golang/geo/s1"
	"github.com/golang/geo/s2"
)

const earthRadiusKm = 6371.01

func main() {
	if err := run(os.Args[1:]); err != nil {
		exitf("%v", err)
	}
}

func run(args []string) error {
	if len(args) == 1 && args[0] == "serve" {
		return runServe()
	}

	output, err := execute(args)
	if err != nil {
		return err
	}

	writeLines(os.Stdout, output)
	return nil
}

func runServe() error {
	scanner := bufio.NewScanner(os.Stdin)
	writer := bufio.NewWriter(os.Stdout)

	for scanner.Scan() {
		output, err := execute(strings.Split(scanner.Text(), "\t"))
		if err != nil {
			writeResponse(writer, []string{"error", sanitizeMessage(err.Error())})
			continue
		}

		writeResponse(writer, append([]string{"ok"}, output...))
	}

	if err := scanner.Err(); err != nil {
		return err
	}

	return nil
}

func execute(args []string) ([]string, error) {
	if len(args) < 4 {
		return nil, errors.New("usage: s2cover <token|covering> <lat> <lng> <level> [radius_km] [max_cells]")
	}

	command, center, level, err := parseSharedArgs(args)
	if err != nil {
		return nil, err
	}

	switch command {
	case "token":
		return []string{s2.CellIDFromLatLng(center).Parent(level).ToToken()}, nil
	case "covering":
		return coveringTokens(center, level, args[4:])
	default:
		return nil, fmt.Errorf("unsupported op: %s", command)
	}
}

func parseSharedArgs(args []string) (string, s2.LatLng, int, error) {
	command := args[0]
	lat, err := parseFloat(args[1], "lat")
	if err != nil {
		return "", s2.LatLng{}, 0, err
	}

	lng, err := parseFloat(args[2], "lng")
	if err != nil {
		return "", s2.LatLng{}, 0, err
	}

	level, err := parseInt(args[3], "level")
	if err != nil {
		return "", s2.LatLng{}, 0, err
	}

	return command, s2.LatLngFromDegrees(lat, lng), level, nil
}

func coveringTokens(center s2.LatLng, level int, args []string) ([]string, error) {
	if len(args) < 1 {
		return nil, errors.New("usage: s2cover covering <lat> <lng> <level> <radius_km> [max_cells]")
	}

	radiusKm, err := parseFloat(args[0], "radius_km")
	if err != nil {
		return nil, err
	}

	coverer, err := buildCoverer(level, args[1:])
	if err != nil {
		return nil, err
	}

	region := s2.CapFromCenterAngle(s2.PointFromLatLng(center), s1.Angle(radiusKm/earthRadiusKm))
	covering := coverer.Covering(region)
	ordered := orderByDistance(center, covering)

	if coverer.MaxCells > 0 && len(ordered) > coverer.MaxCells {
		ordered = ordered[:coverer.MaxCells]
	}

	return ordered, nil
}

func buildCoverer(level int, args []string) (*s2.RegionCoverer, error) {
	coverer := &s2.RegionCoverer{MinLevel: level, MaxLevel: level}

	if len(args) == 0 {
		return coverer, nil
	}

	maxCells, err := parseInt(args[0], "max_cells")
	if err != nil {
		return nil, err
	}

	coverer.MaxCells = maxCells
	return coverer, nil
}

func orderByDistance(center s2.LatLng, covering s2.CellUnion) []string {
	ordered := make([]cellToken, 0, len(covering))

	for _, cellID := range covering {
		cell := s2.CellFromCellID(cellID)
		ordered = append(ordered, cellToken{
			token:    cellID.ToToken(),
			distance: angularDistance(center, s2.LatLngFromPoint(cell.Center())),
		})
	}

	sort.Slice(ordered, func(i, j int) bool {
		if nearlyEqual(ordered[i].distance, ordered[j].distance) {
			return ordered[i].token < ordered[j].token
		}

		return ordered[i].distance < ordered[j].distance
	})

	return projectTokens(ordered)
}

func projectTokens(ordered []cellToken) []string {
	tokens := make([]string, 0, len(ordered))

	for _, cell := range ordered {
		tokens = append(tokens, cell.token)
	}

	return tokens
}

type cellToken struct {
	token    string
	distance float64
}

func angularDistance(a, b s2.LatLng) float64 {
	return float64(a.Distance(b))
}

func nearlyEqual(a, b float64) bool {
	return math.Abs(a-b) < 1e-15
}

func parseFloat(value string, field string) (float64, error) {
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid %s: %w", field, err)
	}

	return parsed, nil
}

func parseInt(value string, field string) (int, error) {
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("invalid %s: %w", field, err)
	}

	return parsed, nil
}

func writeLines(file *os.File, lines []string) {
	for _, line := range lines {
		fmt.Fprintln(file, line)
	}
}

func writeResponse(writer *bufio.Writer, fields []string) {
	_, _ = writer.WriteString(strings.Join(fields, "\t") + "\n")
	_ = writer.Flush()
}

func sanitizeMessage(message string) string {
	message = strings.ReplaceAll(message, "\t", " ")
	return strings.ReplaceAll(message, "\n", " ")
}

func exitf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
