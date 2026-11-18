# The caller's files, newest first.
# variables: $limit (int64)
select Document {
  id,
  title,
  body,
  created_at,
}
order by .updated_at desc empty last then .created_at desc
limit <int64>$limit;
