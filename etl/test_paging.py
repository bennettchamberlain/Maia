import unittest

from etl.paging import advance, next_query


class PagingTest(unittest.TestCase):
    def test_gmail_token_then_the_end(self):
        first = next_query({"nextPageToken": "abc", "messages": [{}, {}]}, {}, 2)
        self.assertEqual(first, {"pageToken": "abc"})
        self.assertIsNone(next_query({"nextPageToken": ""}, {"pageToken": "abc"}, 2))

    def test_slack_cursor(self):
        query = next_query(
            {"messages": [{}], "response_metadata": {"next_cursor": "c1"}},
            {},
            1,
        )
        self.assertEqual(query, {"cursor": "c1"})

    def test_a_full_page_without_a_token_asks_for_the_next_page_number(self):
        query = next_query({"items": [{}] * 30}, {}, 30)
        self.assertEqual(query, {"page": "2"})

    def test_the_same_page_again_means_the_account_is_caught_up(self):
        state = advance(
            {"mode": "backfill", "query": {"page": "2"}, "last_ids": ["a", "b"]},
            {"items": []},
            ["a", "b"],
        )
        self.assertEqual(state["mode"], "caught_up")
        self.assertEqual(state["query"], {})
        self.assertTrue(state["done"])

    def test_a_new_page_keeps_the_backfill_going(self):
        state = advance(
            {"mode": "backfill", "query": {}, "last_ids": []},
            {"nextPageToken": "p2"},
            ["m1"],
        )
        self.assertEqual(state["mode"], "backfill")
        self.assertEqual(state["query"], {"pageToken": "p2"})
        self.assertFalse(state["done"])

    def test_caught_up_reads_the_newest_page_and_stops(self):
        state = advance(
            {"mode": "caught_up", "query": {}, "last_ids": ["old"]},
            {"messages": [{}]},
            ["new"],
        )
        self.assertTrue(state["done"])
        self.assertEqual(state["query"], {})


if __name__ == "__main__":
    unittest.main()
