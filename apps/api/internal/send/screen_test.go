package send

import "testing"

func TestMentionsMatchesWholeWords(t *testing.T) {
	cases := []struct {
		name, text, keyword string
		want                bool
	}{
		{"exact", "bundle of cash", "cash", true},
		{"capitals and punctuation", "CASH!!!", "cash", true},
		{"plural", "two firearms", "firearm", true},
		{"phrase", "a live animal in a box", "live animal", true},
		{"inside another word", "bag of cashew nuts", "cash", false},
		{"inside begun", "work has begun", "gun", false},
		{"unrelated", "school books", "cash", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mentions(normalizeWords(tc.text), tc.keyword); got != tc.want {
				t.Errorf("mentions = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestRequestValidation(t *testing.T) {
	good := Request{SenderName: "A", RecipientName: "B", Item: "books", Size: sizeSmall, Payer: "sender", Timing: "after"}
	if err := good.validate(); err != nil {
		t.Fatalf("validate = %v", err)
	}
	cases := []struct {
		name   string
		change func(*Request)
		want   error
	}{
		{"recipient cannot prepay", func(r *Request) { r.Payer, r.Timing = "recipient", "before" }, ErrInvalidPayment},
		{"unknown size", func(r *Request) { r.Size = "huge" }, ErrInvalidDetails},
		{"blank item", func(r *Request) { r.Item = " " }, ErrInvalidDetails},
		{"negative value", func(r *Request) { r.ItemValueKES = new(int32(-1)) }, ErrInvalidDetails},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := good
			tc.change(&r)
			if err := r.validate(); err != tc.want { //nolint:errorlint // validate returns sentinels unwrapped.
				t.Errorf("validate = %v, want %v", err, tc.want)
			}
		})
	}
}
