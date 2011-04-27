#======================================================================
#                        HA Web Konsole (Hawk)
# --------------------------------------------------------------------
#            A web-based GUI for managing and monitoring the
#          Pacemaker High-Availability cluster resource manager
#
# Copyright (c) 2011 Novell Inc., Tim Serong <tserong@novell.com>
#                        All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it would be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# Further, this software is distributed without any warranty that it is
# free of the rightful claim of any third person regarding infringement
# or the like.  Any license provided herein, whether implied or
# otherwise, applies only to this software file.  Patent licenses, if
# any, provided herein do not apply to combinations of this program with
# other software, or any other product whatsoever.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write the Free Software Foundation,
# Inc., 59 Temple Place - Suite 330, Boston MA 02111-1307, USA.
#
#======================================================================

# Shim to get similar behaviour as ActiveRecord

class CibObject

  class CibObjectError < StandardError
  end

  class RecordNotFound < CibObjectError
  end
  
  class PermissionDenied < CibObjectError
  end

  # Need this to behave like an instance of ActiveRecord
  attr_reader :id
  def to_param
    (id = self.id) ? id.to_s : nil
  end

  def new_record?
    @new_record || false
  end

  def errors
    @errors ||= []
  end

  def save
    error _('Invalid Resource ID "%{id}"') % { :id => @id } unless @id.match(/[a-zA-Z0-9_-]/)
    validate
    return false if errors.any?
    create_or_update
  end

  class << self

    # Check whether anything with the given ID exists, or for a specific
    # element with that ID if type is specified.  Note that we run as
    # hacluster, because we need to verify existence regardless of whether
    # the current user can actually see the object in quesion.
    def exists?(id, type='*')
      Util.safe_x('/usr/sbin/cibadmin', '-Ql', '--xpath', "//configuration//#{type}[@id='#{id}']").chomp != '<null>'
    end

    # Find a CIB object by ID and return an instance of the appropriate
    # class.  Note that if the current user doesn't have read access to
    # the primitive, it appears to result in CibObject::RecordNotFound,
    # due to the way the CIB ACL filtering works internally.
    # TODO(must): really, in the context this is used, we already have
    # a parsed CIB in the Cib object.  We should either *use* this, or
    # ensure CIB in Cib isn't parsed unless actually needed for the
    # status page.
    def find(id)
      begin
        xml = REXML::Document.new(Invoker.instance.cibadmin('-Ql', '--xpath',
          "//configuration//*[self::primitive or self::clone or self::group or self::master][@id='#{id}']"))
        raise CibObject::CibObjectError, _('Unable to parse cibadmin output') unless xml.root
        elem = xml.elements[1]
        obj = class_from_element_name(elem.name).instantiate(elem)
        obj.instance_variable_set(:@id, elem.attributes['id'])
        obj.instance_variable_set(:@xml, elem)
        obj
      rescue SecurityError => e
        raise CibObject::PermissionDenied, e.message
      rescue NotFoundError => e
        raise CibObject::RecordNotFound, e.message
      rescue RuntimeError => e
        raise CibObject::CibObjectError, e.message
      end
    end

    private
    
    def class_from_element_name(name)
      @@map = {
        'primitive' => Primitive,
        'clone'     => Clone,
        'group'     => Group,
        'master'    => Master
      }
      @@map[name]
    end
    
  end

  protected

  def error(msg)
    @errors ||= []
    @errors << msg
  end

  def initialize(attributes = nil)
    @new_record = true
    @id = nil
    set_attributes(attributes)
  end

  def set_attributes(attributes = nil)
    return if attributes.nil?
    ['id', *self.class.instance_variable_get('@attributes')].each do |n|
      instance_variable_set("@#{n}".to_sym, attributes[n]) if attributes.has_key?(n)
    end
  end

  # Override this to add extra validation on save (it's enough
  # to call 'error', no need to return anything in particular)
  def validate
  end

  def create_or_update
    result = new_record? ? create : update
    result != false
  end

  def update_attributes(attributes = nil)
    set_attributes(attributes)
    save  # must be defined in subclass
  end

  def merge_nvpairs(parent, list, attrs)
    if attrs.empty?
      # No attributes to set, get rid of the list (if it exists)
      parent.elements[list].remove if parent.elements[list]
    else
      # Get rid of any attributes that are no longer set
      if parent.elements[list]
        parent.elements[list].elements.each {|e|
          e.remove unless attrs.keys.include? e.attributes['name'] }
      else
        # Add new instance attributes child
        parent.add_element list, { 'id' => "#{parent.attributes['id']}-#{list}" }
      end
      attrs.each do |n,v|
        # update existing, or add new
        nvp = parent.elements["#{list}/nvpair[@name=\"#{n}\"]"]
        if nvp
          nvp.attributes['value'] = v
        else
          parent.elements[list].add_element 'nvpair', {
            'id' => "#{parent.elements[list].attributes['id']}-#{n}",
            'name' => n,
            'value' => v
          }
        end
      end
    end
  end

end

