#!/usr/bin/env ruby

require 'forwardable'

require 'treequel'
require 'treequel/mixins'
require 'treequel/constants'
require 'treequel/branchset'


# The object in Treequel that wraps an entry. It knows how to construct other branches
# for the entries below itself, and how to search for those entries.
#
# == Subversion Id
#
#  $Id$
#
# == Authors
#
# * Michael Granger <ged@FaerieMUD.org>
# * Mahlon E. Smith <mahlon@martini.nu>
#
# :include: LICENSE
#
#---
#
# Please see the file LICENSE in the base directory for licensing details.
#
class Treequel::Branch
	include Treequel::Loggable,
	        Treequel::Constants

	extend Treequel::Delegation


	# SVN Revision
	SVNRev = %q$Rev$

	# SVN Id
	SVNId = %q$Id$


	#################################################################
	###	C L A S S   M E T H O D S
	#################################################################

	### Create a new Treequel::Branch for the specified +dn+ starting from the
	### given +directory+.
	def self::new_from_dn( dn, directory )
		rdn = directory.rdn_to( dn )

		return rdn.split(/,/).reverse.inject( directory ) do |prev, pair|
			attribute, value = pair.split( /=/, 2 )
			Treequel.logger.debug "new_from_dn: fetching %s=%s from %p" % [ attribute, value, prev ]
			prev.send( attribute, value )
		end
	end


	### Create a new Treequel::Branch from the given +entry+ hash from the specified +directory+
	### and +parent+.
	def self::new_from_entry( entry, directory )
		dn = entry['dn']
		rdn, base = dn.first.split( /,/, 2 )
		attribute, value = rdn.split( /=/, 2 )

		return self.new( directory, attribute, value, base, entry )
	end


	#################################################################
	###	I N S T A N C E   M E T H O D S
	#################################################################

	### Create a new Treequel::Branch with the given +directory+, +attribute+, +value+, and
	### +base+. If the optional +entry+ object is given, it will be used to fetch values from
	### the directory; if it isn't provided, it will be fetched from the +directory+ the first
	### time it is needed.
	def initialize( directory, attribute, value, base, entry=nil )
		@directory = directory
		@attribute = attribute
		@value     = value
		@base      = base
		@entry     = entry

		@values = {}
	end


	######
	public
	######

	# Delegate some other methods to a new Branchset via the #branchset method
	def_method_delegators :branchset, :filter, :scope, :select


	# The directory the branch's entry lives in
	attr_reader :directory

	# The DN attribute of the branch
	attr_reader :attribute

	# The value of the DN attribute of the branch
	attr_reader :value

	# The DN of the base of the branch
	attr_reader :base


	### Return the LDAP::Entry associated with the receiver, fetching it from the
	### directory if necessary.
	def entry
		unless @entry
			@entry = self.directory.get_entry( self ) or
				raise "couldn't fetch entry for %p" % [ self ]
		end

		return @entry
	end


	### Return the receiver's Relative Distinguished Name as a String.
	def rdn
		return [ self.attribute, self.value ].join('=')
	end


	### Return the receiver's DN as a String.
	def dn
		return [ self.rdn, self.base ].join(',')
	end
	alias_method :to_s, :dn


	### Return a Treequel::Branchset that will use the receiver as its base.
	def branchset
		return Treequel::Branchset.new( self )
	end


	### Return Treequel::Schema::ObjectClass instances for each of the receiver's
	### objectClass attributes.
	def object_classes
		schema = self.directory.schema
		return self[:objectClass].collect {|oid| schema.object_classes[oid.to_sym] }
	end


	### Return Treequel::Schema::AttributeType instances for each of the receiver's
	### objectClass's MUST attributeTypes.
	def must_attribute_types
		return self.object_classes.collect {|oc| oc.must }.flatten.uniq
	end


	### Return OIDs (numeric OIDs as Strings, named OIDs as Symbols) for each of the receiver's
	### objectClass's MUST attributeTypes.
	def must_oids
		return self.object_classes.collect {|oc| oc.must_oids }.flatten.uniq
	end


	### Return Treequel::Schema::AttributeType instances for each of the receiver's
	### objectClass's MAY attributeTypes.
	def may_attribute_types
		return self.object_classes.collect {|oc| oc.may }.flatten.uniq
	end


	### Return OIDs (numeric OIDs as Strings, named OIDs as Symbols) for each of the receiver's
	### objectClass's MAY attributeTypes.
	def may_oids
		return self.object_classes.collect {|oc| oc.may_oids }.flatten.uniq
	end


	### Return Treequel::Schema::AttributeType instances for the set of all of the receiver's
	### MUST and MAY attributeTypes.
	def valid_attribute_types
		return self.must_attribute_types | self.may_attribute_types
	end


	### Return a uniqified Array of OIDs (numeric OIDs as Strings, named OIDs as Symbols) for
	### the set of all of the receiver's MUST and MAY attributeTypes.
	def valid_attribute_oids
		return self.must_oids | self.may_oids
	end


	### Return +true+ if the specified +attrname+ is a valid attributeType given the
	### receiver's current objectClasses.
	def valid_attribute?( attroid )
		attroid = attroid.to_sym if attroid.is_a?( String ) && 
			attroid !~ NUMERICOID
		return self.valid_attribute_oids.include?( attroid )
	end


	### Returns a human-readable representation of the object suitable for
	### debugging.
	def inspect
		return "#<%s:0x%0x %s @ %s %p>" % [
			self.class.name,
			self.object_id * 2,
			self.dn,
			self.directory,
			self.entry,
		  ]
	end


	### Fetch the value/s associated with the given +attrname+ from the underlying entry.
	def []( attrname )
		attrsym = attrname.to_sym

		unless @values.key?( attrsym )
			self.log.debug "  value is not cached; checking its attributeType"
			unless attribute = self.directory.schema.attribute_types[ attrsym ]
				self.log.info "no attributeType for %p" % [ attrsym ]
				return nil
			end

			self.log.debug "  attribute exists; checking the entry for a value"
			return nil unless (( value = self.entry[attrsym.to_s] ))

			if attribute.single?
				self.log.debug "    attributeType is SINGLE; unwrapping the Array"
				@values[ attrsym ] = value.first
			else
				self.log.debug "    attributeType is not SINGLE; keeping the Array"
				@values[ attrsym ] = value
			end

			@values[ attrsym ].freeze
		else
			self.log.debug "  value is cached."
		end

		return @values[ attrsym ]
	end


	### Set attribute +attrname+ to a new +value+.
	def []=( attrname, value )
		value = [ value ] unless value.is_a?( Array )
		self.log.debug "Modifying %s to %p" % [ attrname, value ]
		self.directory.modify( self, attrname.to_s => value )
		@values.delete( attrname.to_sym )
		self.entry[ attrname.to_s ] = value
	end

# conn.modrdn(dn, new_rdn, delete_old_rdn)

	### Delete the entry associated with the branch from the directory.
	def delete
		self.directory.delete( self )
		return true
	end


	### Create a new child entry under this Branch with the specified +rdn+ and 
	### +attributes+ and return it.
	def create( rdn, attributes={} )
		return self.directory.create( self, rdn, attributes )
	end


	#########
	protected
	#########

	### Proxy method: return a new Branch with the new +attribute+ and +value+ as
	### its base.
	def method_missing( attribute, value, *extra_args )
		raise ArgumentError,
			"wrong number of arguments (%d for 1)" % [ extra_args.length + 1 ] unless
			extra_args.empty?
		return self.class.new( self.directory, attribute, value, self )
	end


	### Clear any cached values when the structural state of the object changes.
	def clear_caches
		@entry = nil
		@values.clear
	end


end # class Treequel::Branch


