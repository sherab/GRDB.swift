// MARK: - QueryInterfaceSelectQueryDefinition

struct QueryInterfaceSelectQueryDefinition {
    var selection: [SQLSelectable]
    var isDistinct: Bool
    var source: SQLSource?
    var whereExpression: SQLExpression?
    var groupByExpressions: [SQLExpression]
    var orderings: [SQLOrderingTerm]
    var isReversed: Bool
    var havingExpression: SQLExpression?
    var limit: SQLLimit?
    
    init(
        select selection: [SQLSelectable],
        isDistinct: Bool = false,
        from source: SQLSource? = nil,
        filter whereExpression: SQLExpression? = nil,
        groupBy groupByExpressions: [SQLExpression] = [],
        orderBy orderings: [SQLOrderingTerm] = [],
        isReversed: Bool = false,
        having havingExpression: SQLExpression? = nil,
        limit: SQLLimit? = nil)
    {
        self.selection = selection
        self.isDistinct = isDistinct
        self.source = source
        self.whereExpression = whereExpression
        self.groupByExpressions = groupByExpressions
        self.orderings = orderings
        self.isReversed = isReversed
        self.havingExpression = havingExpression
        self.limit = limit
    }
    
    func sql(_ arguments: inout StatementArguments?) -> String {
        var sql = "SELECT"
        
        if isDistinct {
            sql += " DISTINCT"
        }
        
        assert(!selection.isEmpty)
        sql += " " + selection.map { $0.resultColumnSQL(&arguments) }.joined(separator: ", ")
        
        if let source = source {
            sql += " FROM " + source.sourceSQL(&arguments)
        }
        
        if let whereExpression = whereExpression {
            sql += " WHERE " + whereExpression.expressionSQL(&arguments)
        }
        
        if !groupByExpressions.isEmpty {
            sql += " GROUP BY " + groupByExpressions.map { $0.expressionSQL(&arguments) }.joined(separator: ", ")
        }
        
        if let havingExpression = havingExpression {
            sql += " HAVING " + havingExpression.expressionSQL(&arguments)
        }
        
        var orderings = self.orderings
        if isReversed {
            if orderings.isEmpty {
                // https://www.sqlite.org/lang_createtable.html#rowid
                //
                // > The rowid value can be accessed using one of the special
                // > case-independent names "rowid", "oid", or "_rowid_" in
                // > place of a column name. If a table contains a user defined
                // > column named "rowid", "oid" or "_rowid_", then that name
                // > always refers the explicitly declared column and cannot be
                // > used to retrieve the integer rowid value.
                //
                // Here we assume that rowid is not a custom column.
                // TODO: support for user-defined rowid column.
                // TODO: support for WITHOUT ROWID tables.
                orderings = [Column.rowID.desc]
            } else {
                orderings = orderings.map { $0.reversed }
            }
        }
        if !orderings.isEmpty {
            sql += " ORDER BY " + orderings.map { $0.orderingTermSQL(&arguments) }.joined(separator: ", ")
        }
        
        if let limit = limit {
            sql += " LIMIT " + limit.sql
        }
        
        return sql
    }
    
    /// Returns a fetch request that counts the number of rows matched by self.
    var countRequest: FetchRequest {
        guard groupByExpressions.isEmpty && limit == nil else {
            // SELECT ... GROUP BY ...
            // SELECT ... LIMIT ...
            return trivialCountQuery
        }
        
        guard let source = source, case .table(name: let tableName, alias: let alias) = source else {
            // SELECT ... FROM (something which is not a table)
            return trivialCountQuery
        }
        
        assert(!selection.isEmpty)
        if selection.count == 1 {
            guard let selectable = self.selection[0].countingSelectable(distinct: isDistinct, from: tableName, aliased: alias) else {
                return trivialCountQuery
            }
            var countQuery = unorderedQuery
            countQuery.isDistinct = false
            countQuery.selection = [selectable]
            return countQuery
        } else {
            // SELECT [DISTINCT] expr1, expr2, ... FROM tableName ...
            
            guard !isDistinct else {
                return trivialCountQuery
            }

            // SELECT expr1, expr2, ... FROM tableName ...
            // ->
            // SELECT COUNT(*) FROM tableName ...
            var countQuery = unorderedQuery
            countQuery.selection = [SQLExpressionCount(star)]
            return countQuery
        }
    }
    
    func makeDeleteStatement(_ db: Database) throws -> UpdateStatement {
        guard groupByExpressions.isEmpty else {
            fatalError("Can't delete query with GROUP BY expression")
        }
        
        guard havingExpression == nil else {
            fatalError("Can't delete query with GROUP BY expression")
        }
        
        guard limit == nil else {
            fatalError("Can't delete query with limit")
        }
        
        var sql = "DELETE"
        var arguments: StatementArguments? = StatementArguments()
        
        if let source = source {
            sql += " FROM " + source.sourceSQL(&arguments)
        }
        
        if let whereExpression = whereExpression {
            sql += " WHERE " + whereExpression.expressionSQL(&arguments)
        }
        
        let statement = try db.makeUpdateStatement(sql)
        statement.arguments = arguments!
        return statement
    }
    
    // SELECT COUNT(*) FROM (self)
    private var trivialCountQuery: QueryInterfaceSelectQueryDefinition {
        return QueryInterfaceSelectQueryDefinition(
            select: [SQLExpressionCount(star)],
            from: .query(query: unorderedQuery, alias: nil))
    }
    
    /// Remove ordering
    private var unorderedQuery: QueryInterfaceSelectQueryDefinition {
        var query = self
        query.isReversed = false
        query.orderings = []
        return query
    }
}

indirect enum SQLSource {
    case table(name: String, alias: String?)
    case query(query: QueryInterfaceSelectQueryDefinition, alias: String?)
    
    func sourceSQL(_ arguments: inout StatementArguments?) -> String {
        switch self {
        case .table(let table, let alias):
            if let alias = alias {
                return table.quotedDatabaseIdentifier + " AS " + alias.quotedDatabaseIdentifier
            } else {
                return table.quotedDatabaseIdentifier
            }
        case .query(let query, let alias):
            if let alias = alias {
                return "(" + query.sql(&arguments) + ") AS " + alias.quotedDatabaseIdentifier
            } else {
                return "(" + query.sql(&arguments) + ")"
            }
        }
    }
}

struct SQLLimit {
    let limit: Int
    let offset: Int?
    
    var sql: String {
        if let offset = offset {
            return "\(limit) OFFSET \(offset)"
        } else {
            return "\(limit)"
        }
    }
}
