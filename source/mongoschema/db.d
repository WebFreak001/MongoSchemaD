/// This module provides the database utility tools which make the whole project useful.
module mongoschema.db;

import core.time;

import mongoschema;

import std.traits;
import std.typecons : BitFlags, tuple, Tuple;

/// Range for iterating over a collection using a Schema.
struct DocumentRange(Schema)
{
	private MongoCursor!(Bson, Bson, typeof(null)) _cursor;

	public this(MongoCursor!(Bson, Bson, typeof(null)) cursor)
	{
		_cursor = cursor;
	}

	/**
		Returns true if there are no more documents for this cursor.

		Throws: An exception if there is a query or communication error.
	*/
	@property bool empty()
	{
		return _cursor.empty;
	}

	/**
		Returns the current document of the response.

		Use empty and popFront to iterate over the list of documents using an
		input range interface. Note that calling this function is only allowed
		if empty returns false.
	*/
	@property Schema front()
	{
		return fromSchemaBson!Schema(_cursor.front);
	}

	/**
		Controls the order in which the query returns matching documents.

		This method must be called before starting to iterate, or an exeption
		will be thrown. If multiple calls to $(D sort()) are issued, only
		the last one will have an effect.

		Params:
			order = A BSON object convertible value that defines the sort order
				of the result. This BSON object must be structured according to
				the MongoDB documentation (see below).

		Returns: Reference to the modified original curser instance.

		Throws:
			An exception if there is a query or communication error.
			Also throws if the method was called after beginning of iteration.

		See_Also: $(LINK http://docs.mongodb.org/manual/reference/method/cursor.sort)
	*/
	auto sort(T)(T order)
	{
		_cursor.sort(serializeToBson(order));
		return this;
	}

	/**
		Limits the number of documents that the cursor returns.

		This method must be called before beginnig iteration in order to have
		effect. If multiple calls to limit() are made, the one with the lowest
		limit will be chosen.

		Params:
			count = The maximum number number of documents to return. A value
				of zero means unlimited.

		Returns: the same cursor

		See_Also: $(LINK http://docs.mongodb.org/manual/reference/method/cursor.limit)
	*/
	auto limit(size_t count)
	{
		_cursor.limit(count);
		return this;
	}

	/**
		Skips a given number of elements at the beginning of the cursor.

		This method must be called before beginnig iteration in order to have
		effect. If multiple calls to skip() are made, the one with the maximum
		number will be chosen.

		Params:
			count = The number of documents to skip.

		Returns: the same cursor

		See_Also: $(LINK http://docs.mongodb.org/manual/reference/method/cursor.skip)
	*/
	auto skip(int count)
	{
		_cursor.skip(count);
		return this;
	}

	/**
		Advances the cursor to the next document of the response.

		Note that calling this function is only allowed if empty returns false.
	*/
	void popFront()
	{
		_cursor.popFront();
	}

	/**
		Iterates over all remaining documents.

		Note that iteration is one-way - elements that have already been visited
		will not be visited again if another iteration is done.

		Throws: An exception if there is a query or communication error.
	*/
	int opApply(int delegate(Schema doc) del)
	{
		while (!_cursor.empty)
		{
			auto doc = _cursor.front;
			_cursor.popFront();
			if (auto ret = del(fromSchemaBson!Schema(doc)))
				return ret;
		}
		return 0;
	}
}

/// Exception thrown if a document could not be found.
class DocumentNotFoundException : Exception
{
	///
	this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc @safe
	{
		super(msg, file, line);
	}
}

///
struct PipelineUnwindOperation
{
	/// Field path to an array field. To specify a field path, prefix the field name with a dollar sign $.
	string path;
	/// Optional. The name of a new field to hold the array index of the element. The name cannot start with a dollar sign $.
	string includeArrayIndex = null;
}

///
struct SchemaPipeline
{
@safe:
	this(MongoCollection collection)
	{
		_collection = collection;
	}

	/// Passes along the documents with only the specified fields to the next stage in the pipeline. The specified fields can be existing fields from the input documents or newly computed fields.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/project/#pipe._S_project
	auto project(Bson specifications)
	{
		assert(!finalized);
		pipeline ~= Bson(["$project" : specifications]);
		return this;
	}

	/// Filters the documents to pass only the documents that match the specified condition(s) to the next pipeline stage.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/match/#pipe._S_match
	auto match(Bson query)
	{
		assert(!finalized);
		pipeline ~= Bson(["$match" : query]);
		return this;
	}

	/// Restricts the contents of the documents based on information stored in the documents themselves.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/redact/#pipe._S_redact
	auto redact(Bson expression)
	{
		assert(!finalized);
		pipeline ~= Bson(["$redact" : expression]);
		return this;
	}

	/// Limits the number of documents passed to the next stage in the pipeline.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/limit/#pipe._S_limit
	auto limit(size_t count)
	{
		assert(!finalized);
		pipeline ~= Bson(["$limit" : Bson(count)]);
		return this;
	}

	/// Skips over the specified number of documents that pass into the stage and passes the remaining documents to the next stage in the pipeline.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/skip/#pipe._S_skip
	auto skip(size_t count)
	{
		assert(!finalized);
		pipeline ~= Bson(["$skip" : Bson(count)]);
		return this;
	}

	/// Deconstructs an array field from the input documents to output a document for each element. Each output document is the input document with the value of the array field replaced by the element.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/unwind/#pipe._S_unwind
	auto unwind(string path)
	{
		assert(!finalized);
		pipeline ~= Bson(["$unwind" : Bson(path)]);
		return this;
	}

	/// Deconstructs an array field from the input documents to output a document for each element. Each output document is the input document with the value of the array field replaced by the element.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/unwind/#pipe._S_unwind
	auto unwind(PipelineUnwindOperation op)
	{
		assert(!finalized);
		Bson opb = Bson(["path" : Bson(op.path)]);
		if (op.includeArrayIndex !is null)
			opb["includeArrayIndex"] = Bson(op.includeArrayIndex);
		pipeline ~= Bson(["$unwind" : opb]);
		return this;
	}

	/// Deconstructs an array field from the input documents to output a document for each element. Each output document is the input document with the value of the array field replaced by the element.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/unwind/#pipe._S_unwind
	auto unwind(PipelineUnwindOperation op, bool preserveNullAndEmptyArrays)
	{
		assert(!finalized);
		Bson opb = Bson(["path" : Bson(op.path), "preserveNullAndEmptyArrays"
				: Bson(preserveNullAndEmptyArrays)]);
		if (op.includeArrayIndex !is null)
			opb["includeArrayIndex"] = Bson(op.includeArrayIndex);
		pipeline ~= Bson(["$unwind" : opb]);
		return this;
	}

	/// Groups documents by some specified expression and outputs to the next stage a document for each distinct grouping. The output documents contain an _id field which contains the distinct group by key. The output documents can also contain computed fields that hold the values of some accumulator expression grouped by the $group‘s _id field. $group does not order its output documents.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/group/#pipe._S_group
	auto group(Bson id, Bson[string] accumulators)
	{
		assert(!finalized);
		accumulators["_id"] = id;
		pipeline ~= Bson(["$group" : Bson(accumulators)]);
		return this;
	}

	/// Groups all documents into one specified with the accumulators. Basically just runs group(null, accumulators)
	auto groupAll(Bson[string] accumulators)
	{
		assert(!finalized);
		accumulators["_id"] = Bson(null);
		pipeline ~= Bson(["$group" : Bson(accumulators)]);
		return this;
	}

	/// Randomly selects the specified number of documents from its input.
	/// Warning: $sample may output the same document more than once in its result set.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/sample/#pipe._S_sample
	auto sample(size_t count)
	{
		assert(!finalized);
		pipeline ~= Bson(["$sample" : Bson(count)]);
		return this;
	}

	/// Sorts all input documents and returns them to the pipeline in sorted order.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/sort/#pipe._S_sort
	auto sort(Bson sorter)
	{
		assert(!finalized);
		pipeline ~= Bson(["$sort" : sorter]);
		return this;
	}

	/// Outputs documents in order of nearest to farthest from a specified point.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/geoNear/#pipe._S_geoNear
	auto geoNear(Bson options)
	{
		assert(!finalized);
		pipeline ~= Bson(["$geoNear" : options]);
		return this;
	}

	/// Performs a left outer join to an unsharded collection in the same database to filter in documents from the “joined” collection for processing. The $lookup stage does an equality match between a field from the input documents with a field from the documents of the “joined” collection.
	/// To each input document, the $lookup stage adds a new array field whose elements are the matching documents from the “joined” collection. The $lookup stage passes these reshaped documents to the next stage.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/lookup/#pipe._S_lookup
	auto lookup(Bson options)
	{
		assert(!finalized);
		pipeline ~= Bson(["$lookup" : options]);
		return this;
	}

	/// Takes the documents returned by the aggregation pipeline and writes them to a specified collection. The $out operator must be the last stage in the pipeline. The $out operator lets the aggregation framework return result sets of any size.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/out/#pipe._S_out
	auto outputTo(string outputCollection)
	{
		assert(!finalized);
		debug finalized = true;
		pipeline ~= Bson(["$out" : Bson(outputCollection)]);
		return this;
	}

	/// Returns statistics regarding the use of each index for the collection. If running with access control, the user must have privileges that include indexStats action.
	/// MongoDB Documentation: https://docs.mongodb.com/manual/reference/operator/aggregation/indexStats/#pipe._S_indexStats
	auto indexStats()
	{
		assert(!finalized);
		pipeline ~= Bson(["$indexStats" : Bson.emptyObject]);
		return this;
	}

	Bson run()
	{
		debug finalized = true;
		return _collection.aggregate(pipeline);
	}

	DocumentRange!T collect(T = Bson)(AggregateOptions options = AggregateOptions.init)
	{
		debug finalized = true;
		return _collection.aggregate!T(pipeline, options);
	}

private:
	bool finalized = false;
	Bson[] pipeline;
	MongoCollection _collection;
}

/// Mixin for functions for interacting with Mongo collections.
mixin template MongoSchema()
{
	import std.typecons : Nullable;
	import std.range : isInputRange, ElementType;

	static MongoCollection _schema_collection_;
	private BsonObjectID _schema_object_id_;

	@property static MongoCollection collection() @safe
	{
		return _schema_collection_;
	}

	/// Returns: the _id value (if set by save or find)
	@property ref BsonObjectID bsonID() @safe
	{
		return _schema_object_id_;
	}

	/// Inserts or updates an existing value.
	void save()
	{
		if (_schema_object_id_.valid)
		{
			collection.update(Bson(["_id" : Bson(_schema_object_id_)]),
					this.toSchemaBson(), UpdateFlags.upsert);
		}
		else
		{
			_schema_object_id_ = BsonObjectID.generate;
			auto bson = this.toSchemaBson();
			collection.insert(bson);
		}
	}

	/// Inserts or merges into an existing value.
	void merge()
	{
		if (_schema_object_id_.valid)
		{
			collection.update(Bson(["_id" : Bson(_schema_object_id_)]),
					Bson(["$set": this.toSchemaBson()]), UpdateFlags.upsert);
		}
		else
		{
			_schema_object_id_ = BsonObjectID.generate;
			auto bson = this.toSchemaBson();
			collection.insert(bson);
		}
	}

	/// Removes this object from the collection. Returns false when _id of this is not set.
	bool remove() @safe const
	{
		if (!_schema_object_id_.valid)
			return false;
		collection.remove(Bson(["_id" : Bson(_schema_object_id_)]),
				DeleteFlags.SingleRemove);
		return true;
	}

	/// Tries to find one document in the collection.
	/// Throws: DocumentNotFoundException if not found
	static Bson findOneOrThrow(T)(T query)
	{
		Bson found = collection.findOne(query);
		if (found.isNull)
			throw new DocumentNotFoundException("Could not find one " ~ typeof(this).stringof);
		return found;
	}

	/// Finds one element with the object id `id`.
	/// Throws: DocumentNotFoundException if not found
	static typeof(this) findById(BsonObjectID id)
	{
		return fromSchemaBson!(typeof(this))(findOneOrThrow(Bson(["_id" : Bson(id)])));
	}

	/// Finds one element with the hex id `id`.
	/// Throws: DocumentNotFoundException if not found
	static typeof(this) findById(string id)
	{
		return findById(BsonObjectID.fromString(id));
	}

	/// Finds one element using a query.
	/// Throws: DocumentNotFoundException if not found
	static typeof(this) findOne(T)(T query)
	{
		return fromSchemaBson!(typeof(this))(findOneOrThrow(query));
	}

	/// Tries to find a document by the _id field and returns a Nullable which `isNull` if it could not be found. Otherwise it will be the document wrapped in the nullable.
	static Nullable!(typeof(this)) tryFindById(BsonObjectID id)
	{
		Bson found = collection.findOne(Bson(["_id" : Bson(id)]));
		if (found.isNull)
			return Nullable!(typeof(this)).init;
		return Nullable!(typeof(this))(fromSchemaBson!(typeof(this))(found));
	}

	/// ditto
	static Nullable!(typeof(this)) tryFindById(string id)
	{
		return tryFindById(BsonObjectID.fromString(id));
	}

	/// Tries to find a document in this collection. It will return a Nullable which `isNull` if the document could not be found. Otherwise it will be the document wrapped in the nullable.
	static Nullable!(typeof(this)) tryFindOne(T)(T query)
	{
		Bson found = collection.findOne(query);
		if (found.isNull)
			return Nullable!(typeof(this)).init;
		return Nullable!(typeof(this))(fromSchemaBson!(typeof(this))(found));
	}

	/// Tries to find a document by the _id field and returns a default value if it could not be found.
	static typeof(this) tryFindById(BsonObjectID id, typeof(this) defaultValue)
	{
		Bson found = collection.findOne(Bson(["_id" : Bson(id)]));
		if (found.isNull)
			return defaultValue;
		return fromSchemaBson!(typeof(this))(found);
	}

	/// ditto
	static typeof(this) tryFindById(string id, typeof(this) defaultValue)
	{
		return tryFindById(BsonObjectID.fromString(id), defaultValue);
	}

	/// Tries to find a document in this collection. It will return a default value if the document could not be found.
	static typeof(this) tryFindOne(T)(T query, typeof(this) defaultValue)
	{
		Bson found = collection.findOne(query);
		if (found.isNull)
			return defaultValue;
		return fromSchemaBson!(typeof(this))(found);
	}

	/// Finds one or more elements using a query.
	static typeof(this)[] find(T)(T query, QueryFlags flags = QueryFlags.None,
			int num_skip = 0, int num_docs_per_chunk = 0)
	{
		typeof(this)[] values;
		foreach (entry; collection.find(query, null, flags, num_skip, num_docs_per_chunk))
		{
			values ~= fromSchemaBson!(typeof(this))(entry);
		}
		return values;
	}

	/// Queries all elements from the collection.
	deprecated("use findAll instead") static typeof(this)[] find()
	{
		typeof(this)[] values;
		foreach (entry; collection.find())
		{
			values ~= fromSchemaBson!(typeof(this))(entry);
		}
		return values;
	}

	/// Finds one or more elements using a query as range.
	static DocumentRange!(typeof(this)) findRange(T)(T query,
			QueryFlags flags = QueryFlags.None, int num_skip = 0, int num_docs_per_chunk = 0)
	{
		return DocumentRange!(typeof(this))(collection.find(serializeToBson(query),
				null, flags, num_skip, num_docs_per_chunk));
	}

	/// Queries all elements from the collection as range.
	static DocumentRange!(typeof(this)) findAll()
	{
		return DocumentRange!(typeof(this))(collection.find());
	}

	/// Inserts many documents at once. The resulting IDs of the symbols will be generated by the server and not known to the caller.
	static void insertMany(T)(T documents, InsertFlags options = InsertFlags.none)
		if (isInputRange!T && is(ElementType!T : typeof(this)))
	{
		import std.array : array;
		import std.algorithm : map;

		if (documents.empty)
			return;
		collection.insert(documents.map!((a) {
				a.bsonID = BsonObjectID.init;
				return a.toSchemaBson;
			}).array, options); // .array needed because of vibe-d issue #2185
	}

	/// Updates a document.
	static void update(T, U)(T query, U update, UpdateFlags options = UpdateFlags.none)
	{
		collection.update(query, update, options);
	}

	/// Updates a document or inserts it when not existent. Shorthand for `update(..., UpdateFlags.upsert)`
	static void upsert(T, U)(T query, U update, UpdateFlags options = UpdateFlags.upsert)
	{
		collection.update(query, update, options);
	}

	/// Deletes one or any amount of documents matching the selector based on the flags.
	static void remove(T)(T selector, DeleteFlags flags = DeleteFlags.none)
	{
		collection.remove(selector, flags);
	}

	/// Removes all documents from this collection.
	static void removeAll()
	{
		collection.remove();
	}

	/// Drops the entire collection and all indices in the database.
	static void dropTable()
	{
		collection.drop();
	}

	/// Returns the count of documents in this collection matching this query.
	static auto count(T)(T query)
	{
		return collection.count(query);
	}

	/// Returns the count of documents in this collection.
	static auto countAll()
	{
		import vibe.data.bson : Bson;

		return collection.count(Bson.emptyObject);
	}

	/// Start of an aggregation call. Returns a pipeline with typesafe functions for modifying the pipeline and running it at the end.
	/// Examples:
	/// --------------------
	/// auto groupResults = Book.aggregate.groupAll([
	/// 	"totalPrice": Bson([
	/// 		"$sum": Bson([
	/// 			"$multiply": Bson([Bson("$price"), Bson("$quantity")])
	/// 		])
	/// 	]),
	/// 	"averageQuantity": Bson([
	/// 		"$avg": Bson("$quantity")
	/// 	]),
	/// 	"count": Bson(["$sum": Bson(1)])
	/// ]).run;
	/// --------------------
	static SchemaPipeline aggregate()
	{
		return SchemaPipeline(collection);
	}
}

/// Binds a MongoCollection to a Schema. Can only be done once!
void register(T)(MongoCollection collection) @safe
{
	T obj = T.init;

	static if (hasMember!(T, "_schema_collection_"))
	{
		(() @trusted {
			assert(T._schema_collection_.name.length == 0, "Can't register a Schema to 2 collections!");
			T._schema_collection_ = collection;
		})();
	}

	foreach (memberName; __traits(allMembers, T))
	{
		static if (__traits(compiles, {
				static s = isVariable!(__traits(getMember, obj, memberName));
			}) && isVariable!(__traits(getMember, obj, memberName)))
		{
			static if (__traits(getProtection, __traits(getMember, obj, memberName)) == "public")
			{
				string name = memberName;
				static if (!hasUDA!((__traits(getMember, obj, memberName)), schemaIgnore))
				{
					static if (hasUDA!((__traits(getMember, obj, memberName)), schemaName))
					{
						static assert(getUDAs!((__traits(getMember, obj, memberName)), schemaName)
								.length == 1, "Member '" ~ memberName ~ "' can only have one name!");
						name = getUDAs!((__traits(getMember, obj, memberName)), schemaName)[0].name;
					}

					IndexFlags flags = IndexFlags.None;
					ulong expires = 0LU;
					bool force;

					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoForceIndex))
					{
						force = true;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoBackground))
					{
						flags |= IndexFlags.Background;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)),
							mongoDropDuplicates))
					{
						flags |= IndexFlags.DropDuplicates;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoSparse))
					{
						flags |= IndexFlags.Sparse;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoUnique))
					{
						flags |= IndexFlags.Unique;
					}
					static if (hasUDA!((__traits(getMember, obj, memberName)), mongoExpire))
					{
						static assert(getUDAs!((__traits(getMember, obj, memberName)), mongoExpire).length == 1,
								"Member '" ~ memberName ~ "' can only have one expiry value!");
						flags |= IndexFlags.ExpireAfterSeconds;
						expires = getUDAs!((__traits(getMember, obj, memberName)), mongoExpire)[0]
							.seconds;
					}

					if (flags != IndexFlags.None || force)
						collection.ensureIndex([tuple(name, 1)], flags, dur!"seconds"(expires));
				}
			}
		}
	}
}

unittest
{
	struct C
	{
		int a = 4;
	}

	struct B
	{
		C cref;
	}

	struct A
	{
		B bref;
	}

	A a;
	a.bref.cref.a = 5;
	auto bson = a.toSchemaBson();
	assert(bson["bref"]["cref"]["a"].get!int == 5);
	A b = bson.fromSchemaBson!A();
	assert(b.bref.cref.a == 5);
}

unittest
{
	import std.digest.digest;
	import std.digest.sha;

	enum Activity
	{
		High,
		Medium,
		Low
	}

	enum Permission
	{
		A = 1,
		B = 2,
		C = 4
	}

	struct UserSchema
	{
		string username = "Unnamed";
		@binaryType()
		string salt = "foobar";
		@encode("encodePassword")
		@binaryType()
		string password;
		@schemaName("date-created")
		SchemaDate dateCreated = SchemaDate.now;
		Activity activity = Activity.Medium;
		BitFlags!Permission permissions;
		Tuple!(string, string) name;

		Bson encodePassword(UserSchema user)
		{
			// TODO: Replace with something more secure
			return Bson(BsonBinData(BsonBinData.Type.generic, sha1Of(user.password ~ user.salt)));
		}
	}

	auto user = UserSchema();
	user.password = "12345";
	user.username = "Bob";
	user.permissions = Permission.A | Permission.C;
	user.name = tuple("Bob", "Bobby");
	auto bson = user.toSchemaBson();
	assert(bson["username"].get!string == "Bob");
	assert(bson["date-created"].get!(BsonDate).value > 0);
	assert(bson["activity"].get!(int) == cast(int) Activity.Medium);
	assert(bson["salt"].get!(BsonBinData).rawData == cast(ubyte[]) "foobar");
	assert(bson["password"].get!(BsonBinData).rawData == sha1Of(user.password ~ user.salt));
	assert(bson["permissions"].get!(int) == 5);
	assert(bson["name"].get!(Bson[]).length == 2);

	auto user2 = bson.fromSchemaBson!UserSchema();
	assert(user2.username == user.username);
	assert(user2.password != user.password);
	assert(user2.salt == user.salt);
	// dates are gonna differ as `user2` has the current time now and `user` a magic value to get the current time
	assert(user2.dateCreated != user.dateCreated);
	assert(user2.activity == user.activity);
	assert(user2.permissions == user.permissions);
	assert(user2.name == user.name);
}

unittest
{
	import vibe.db.mongo.mongo;
	import std.digest.sha;
	import std.exception;
	import std.array;

	auto client = connectMongoDB("127.0.0.1");
	auto database = client.getDatabase("test");
	MongoCollection users = database["users"];
	users.remove(); // Clears collection

	struct User
	{
		mixin MongoSchema;

		@mongoUnique string username;
		@binaryType()
		ubyte[] hash;
		@schemaName("profile-picture")
		string profilePicture;
		auto registered = SchemaDate.now;
	}

	users.register!User;

	assert(User.findAll().array.length == 0);

	User user;
	user.username = "Example";
	user.hash = sha512Of("password123");
	user.profilePicture = "example-avatar.png";

	assertNotThrown(user.save());

	User user2;
	user2.username = "Bob";
	user2.hash = sha512Of("foobar");
	user2.profilePicture = "bob-avatar.png";

	assertNotThrown(user2.save());

	User faker;
	faker.username = "Example";
	faker.hash = sha512Of("PASSWORD");
	faker.profilePicture = "example-avatar.png";

	assertThrown(faker.save());
	// Unique username

	faker.username = "Example_";
	assertNotThrown(faker.save());

	user.username = "NewExample";
	user.save();

	auto actualFakeID = faker.bsonID;
	faker = User.findOne(["username" : "NewExample"]);

	assert(actualFakeID != faker.bsonID);

	foreach (usr; User.findAll)
	{
		usr.profilePicture = "default.png"; // Reset all profile pictures
		usr.save();
	}
	user = User.findOne(["username" : "NewExample"]);
	user2 = User.findOne(["username" : "Bob"]);
	faker = User.findOne(["username" : "Example_"]);
	assert(user.profilePicture == user2.profilePicture
			&& user2.profilePicture == faker.profilePicture && faker.profilePicture == "default.png");

	User user3;
	user3.username = "User123";
	user3.hash = sha512Of("486951");
	user3.profilePicture = "new.png";
	User.upsert(["username" : "User123"], user3.toSchemaBson);
	user3 = User.findOne(["username" : "User123"]);
	assert(user3.hash == sha512Of("486951"));
	assert(user3.profilePicture == "new.png");
}

unittest
{
	import vibe.db.mongo.mongo;
	import mongoschema.aliases : name, ignore, unique, binary;
	import std.digest.sha;
	import std.digest.md;

	auto client = connectMongoDB("127.0.0.1");

	struct Permission
	{
		string name;
		int priority;
	}

	struct User
	{
		mixin MongoSchema;

		@unique string username;

		@binary()
		ubyte[] hash;
		@binary()
		ubyte[] salt;

		@name("profile-picture")
		string profilePicture = "default.png";

		Permission[] permissions;

	@ignore:
		int sessionID;
	}

	auto coll = client.getCollection("test.users2");
	coll.remove();
	coll.register!User;

	User register(string name, string password)
	{
		User user;
		user.username = name;
		user.salt = md5Of(name).dup;
		user.hash = sha512Of(cast(ubyte[]) password ~ user.salt).dup;
		user.permissions ~= Permission("forum.access", 1);
		user.save();
		return user;
	}

	User find(string name)
	{
		return User.findOne(["username" : name]);
	}

	User a = register("foo", "bar");
	User b = find("foo");
	assert(a == b);
}