// Package mobile is the narrow gomobile binding used by Flutter's platform channel.
package mobile

import "juku/internal/app"

type Client struct{ core *app.MobileClient }

func NewClient(directory string) (*Client, error) {
	core, err := app.NewMobileClient(directory)
	if err != nil {
		return nil, err
	}
	return &Client{core: core}, nil
}

func (c *Client) Call(request string) (string, error) { return c.core.Call(request) }
func (c *Client) Close()                              { c.core.Close() }
