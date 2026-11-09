package httpapi

import (
	"context"

	"github.com/kelvinguchu/liddr/apps/api/internal/ratings"
)

// ListPendingRatings lists ratings still open to the user.
func (a *API) ListPendingRatings(ctx context.Context, _ ListPendingRatingsRequestObject) (ListPendingRatingsResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	pending, err := a.deps.Ratings.ListPending(ctx, p.UserID)
	if err != nil {
		return nil, err
	}
	data := make([]PendingRating, len(pending))
	for i, item := range pending {
		data[i] = PendingRating{RideId: item.RideID, RaterRole: item.RaterRole, DueAt: item.DueAt, CompletedAt: item.CompletedAt}
	}
	return ListPendingRatings200JSONResponse{Data: data}, nil
}

// RateRide records a rating.
func (a *API) RateRide(ctx context.Context, req RateRideRequestObject) (RateRideResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	sub := ratings.Submission{RideID: req.RideId, RaterID: p.UserID, Score: req.Body.Score, Comment: req.Body.Comment}
	if req.Body.ReasonTags != nil {
		sub.Tags = *req.Body.ReasonTags
	}
	if err := a.deps.Ratings.Rate(ctx, sub); err != nil {
		return nil, err
	}
	return RateRide204Response{}, nil
}

// SkipRating declines to rate.
func (a *API) SkipRating(ctx context.Context, req SkipRatingRequestObject) (SkipRatingResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Ratings.Skip(ctx, req.RideId, p.UserID); err != nil {
		return nil, err
	}
	return SkipRating204Response{}, nil
}

// ListRatings returns ratings for staff.
func (a *API) ListRatings(ctx context.Context, req ListRatingsRequestObject) (ListRatingsResponseObject, error) {
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	excludedOnly := req.Params.ExcludedOnly != nil && *req.Params.ExcludedOnly
	items, err := a.deps.Ratings.List(ctx, req.Params.RatedUserId, excludedOnly, limit, offset)
	if err != nil {
		return nil, err
	}
	data := make([]Rating, len(items))
	for i, r := range items {
		data[i] = Rating{
			Id: r.ID, RideId: r.RideID, RatedBy: r.RatedBy, RatedUser: r.RatedUser, Score: r.Score, ReasonTags: r.Tags,
			Comment: r.Comment, IncludeInScore: r.IncludeInScore, ExclusionReason: r.ExclusionReason, NullifiedAt: r.NullifiedAt, SubmittedAt: r.SubmittedAt,
		}
	}
	return ListRatings200JSONResponse{Data: data}, nil
}

// NullifyRating removes a rating from the score.
func (a *API) NullifyRating(ctx context.Context, req NullifyRatingRequestObject) (NullifyRatingResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Ratings.Nullify(ctx, req.RatingId, actor.UserID, req.Body.Reason, actor.RequestID); err != nil {
		return nil, err
	}
	return NullifyRating204Response{}, nil
}

// ReinstateRating restores a rating.
func (a *API) ReinstateRating(ctx context.Context, req ReinstateRatingRequestObject) (ReinstateRatingResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Ratings.Reinstate(ctx, req.RatingId, actor.UserID, actor.RequestID); err != nil {
		return nil, err
	}
	return ReinstateRating204Response{}, nil
}
