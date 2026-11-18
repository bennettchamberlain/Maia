# variables: $source (str), $ids (array<str>)
select MemoryItem {
  source_id,
}
filter .owner = global current_person
  and .source = <str>$source
  and .source_id in array_unpack(<array<str>>$ids)
  and exists .body
  and .body != '';
