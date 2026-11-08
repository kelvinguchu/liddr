// Package rides owns vehicle categories, quotes, booking and the trip lifecycle.
package rides

import (
	"context"
	"fmt"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Category is a vehicle category offered on the platform.
type Category struct {
	Slug                  string
	Label                 string
	Capacity              int32
	WeeklySubscriptionKES int32
}

// Catalog reads the vehicle category registry.
type Catalog struct {
	queries *store.Queries
}

// NewCatalog returns a Catalog backed by queries.
func NewCatalog(queries *store.Queries) *Catalog {
	return &Catalog{queries: queries}
}

// ActiveCategories returns the categories currently offered, in display order.
func (c *Catalog) ActiveCategories(ctx context.Context) ([]Category, error) {
	rows, err := c.queries.ListActiveVehicleCategories(ctx)
	if err != nil {
		return nil, fmt.Errorf("list active vehicle categories: %w", err)
	}
	categories := make([]Category, len(rows))
	for i, row := range rows {
		categories[i] = Category{
			Slug:                  row.Slug,
			Label:                 row.Label,
			Capacity:              row.Capacity,
			WeeklySubscriptionKES: row.WeeklySubscriptionKes,
		}
	}
	return categories, nil
}
