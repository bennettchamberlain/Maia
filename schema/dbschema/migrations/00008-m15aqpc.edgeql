CREATE MIGRATION m15aqpckrejgg5xr6zq55owzjgqeqth2ai73mj3doye6jyuih3hl7q
    ONTO m14cqgnhheuc5iz6ktjxcdmv3bhlxghdbtxshodxcembgc5swm7emq
{
  CREATE TYPE default::ClientFault {
      CREATE ACCESS POLICY service_records
          ALLOW SELECT, INSERT USING ((GLOBAL default::service_mode ?? false));
      CREATE LINK person: default::Person;
      CREATE REQUIRED PROPERTY created_at: std::datetime {
          SET default := (std::datetime_of_statement());
      };
      CREATE INDEX ON ((.person, .created_at));
      CREATE INDEX ON (.created_at);
      CREATE REQUIRED PROPERTY action: std::str;
      CREATE PROPERTY client: std::str;
      CREATE REQUIRED PROPERTY detail: std::str;
      CREATE REQUIRED PROPERTY kind: std::str;
      CREATE REQUIRED PROPERTY ref: std::str {
          CREATE CONSTRAINT std::exclusive;
      };
      CREATE PROPERTY route: std::str;
      CREATE REQUIRED PROPERTY summary: std::str;
  };
};
