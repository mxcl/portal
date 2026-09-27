CREATE TABLE merged_work (
    device BLOB NOT NULL,
    repository TEXT NOT NULL,
    id BLOB NOT NULL,
    pr INTEGER NOT NULL,
    oid TEXT NOT NULL,
    record TEXT NOT NULL,
    completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0,1)),
    PRIMARY KEY(device, repository, pr, oid),
    UNIQUE(device, id),
    FOREIGN KEY(device, repository) REFERENCES tracked(device, repository) ON DELETE CASCADE
);
