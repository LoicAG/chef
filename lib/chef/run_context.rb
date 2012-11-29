#
# Author:: Adam Jacob (<adam@opscode.com>)
# Author:: Christopher Walters (<cw@opscode.com>)
# Author:: Tim Hinderliter (<tim@opscode.com>)
# Copyright:: Copyright (c) 2008-2010 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'chef/resource_collection'
require 'chef/cookbook_version'
require 'chef/node'
require 'chef/role'
require 'chef/log'

class Chef
  # == Chef::RunContext
  # Value object that loads and tracks the context of a Chef run
  class RunContext

    # Implements the compile phase of the chef run by loading/eval-ing files
    # from cookbooks in the correct order and in the correct context.
    class CookbookCompiler
      attr_reader :node
      attr_reader :events
      attr_reader :run_list_expansion
      attr_reader :cookbook_collection

      # Resource Definitions from the compiled cookbooks. This is populated by
      # calling #compile_resource_definitions (which is called by #compile)
      attr_reader :definitions

      def initialize(node, cookbook_collection, run_list_expansion, events)
        @node = node
        @events = events
        @run_list_expansion = run_list_expansion
        @cookbook_collection = cookbook_collection

        # @resource_collection = Chef::ResourceCollection.new
        # @immediate_notification_collection = Hash.new {|h,k| h[k] = []}
        # @delayed_notification_collection = Hash.new {|h,k| h[k] = []}
        # @loaded_recipes = {}
        # @loaded_attributes = {}
        #

        @definitions = Hash.new
        @cookbook_order = nil
      end

      # Run the compile phase of the chef run. Loads files in the following order:
      # * Libraries
      # * Attributes
      # * LWRPs
      # * Resource Definitions
      # * Recipes
      #
      # Recipes are loaded in precisely the order specified by the expanded run_list.
      #
      # Other files are loaded in an order derived from the expanded run_list
      # and the dependencies declared by cookbooks' metadata. See
      # #cookbook_order for more information.
      def compile
        compile_libraries
        compile_attributes
        compile_lwrps
        compile_resource_definitions
        #compile_recipes
      end

      # Extracts the cookbook names from the expanded run list, then iterates
      # over the list, recursing through dependencies to give a run_list
      # ordered array of cookbook names with no duplicates. Dependencies appear
      # before the cookbook they depend on.
      def cookbook_order
        @cookbook_order ||= begin
          ordered_cookbooks = []
          seen_cookbooks = {}
          run_list_expansion.recipes.each do |recipe|
            cookbook = Chef::Recipe.parse_recipe_name(recipe).first
            add_cookbook_with_deps(ordered_cookbooks, seen_cookbooks, cookbook)
          end
          ordered_cookbooks
        end
      end

      # Loads library files from cookbooks according to #cookbook_order.
      def compile_libraries
        @events.library_load_start(count_files_by_segment(:libraries))
        cookbook_order.each do |cookbook|
          load_libraries_from_cookbook(cookbook)
        end
        @events.library_load_complete
      end

      # Loads attributes files from cookbooks. Attributes files are loaded
      # according to #cookbook_order; within a cookbook, +default.rb+ is loaded
      # first, then the remaining attributes files in lexical sort order.
      def compile_attributes
        @events.attribute_load_start(count_files_by_segment(:attributes))
        cookbook_order.each do |cookbook|
          load_attributes_from_cookbook(cookbook)
        end
        @events.attribute_load_complete
      end

      # Loads LWRPs according to #cookbook_order. Providers are loaded before
      # resources on a cookbook-wise basis.
      def compile_lwrps
        lwrp_file_count = count_files_by_segment(:providers) + count_files_by_segment(:resources)
        @events.lwrp_load_start(lwrp_file_count)
        cookbook_order.each do |cookbook|
          load_lwrps_from_cookbook(cookbook)
        end
        @events.lwrp_load_complete
      end

      def compile_resource_definitions
        @events.definition_load_start(count_files_by_segment(:definitions))
        cookbook_order.each do |cookbook|
          load_resource_definitions_from_cookbook(cookbook)
        end
        @events.definition_load_complete
      end


      private

      def load_attributes_from_cookbook(cookbook_name)
        list_of_attr_files = files_in_cookbook_by_segment(cookbook_name, :attributes).dup
        if default_file = list_of_attr_files.find {|path| File.basename(path) == "default.rb" }
          list_of_attr_files.delete(default_file)
          load_attribute_file(cookbook_name.to_s, default_file)
        end

        list_of_attr_files.each do |filename|
          load_attribute_file(cookbook_name.to_s, filename)
        end
      end

      def load_attribute_file(cookbook_name, filename)
        Chef::Log.debug("Node #{@node.name} loading cookbook #{cookbook_name}'s attribute file #{filename}")
        attr_file_basename = ::File.basename(filename, ".rb")
        @node.include_attribute("#{cookbook_name}::#{attr_file_basename}")
      rescue Exception => e
        @events.attribute_file_load_failed(filename, e)
        raise
      end

      def load_libraries_from_cookbook(cookbook_name)
        files_in_cookbook_by_segment(cookbook_name, :libraries).each do |filename|
          begin
            Chef::Log.debug("Loading cookbook #{cookbook_name}'s library file: #{filename}")
            Kernel.load(filename)
            @events.library_file_loaded(filename)
          rescue Exception => e
            @events.library_file_load_failed(filename, e)
            raise
          end
        end
      end

      def load_lwrps_from_cookbook(cookbook_name)
        files_in_cookbook_by_segment(cookbook_name, :providers).each do |filename|
          load_lwrp_provider(cookbook_name, filename)
        end
        files_in_cookbook_by_segment(cookbook_name, :resources).each do |filename|
          load_lwrp_resource(cookbook_name, filename)
        end
      end

      def load_lwrp_provider(cookbook_name, filename)
        Chef::Log.debug("Loading cookbook #{cookbook_name}'s providers from #{filename}")
        Chef::Provider.build_from_file(cookbook_name, filename, self)
        @events.lwrp_file_loaded(filename)
      rescue Exception => e
        @events.lwrp_file_load_failed(filename, e)
        raise
      end

      def load_lwrp_resource(cookbook_name, filename)
        Chef::Log.debug("Loading cookbook #{cookbook_name}'s resources from #{filename}")
        Chef::Resource.build_from_file(cookbook_name, filename, self)
        @events.lwrp_file_loaded(filename)
      rescue Exception => e
        @events.lwrp_file_load_failed(filename, e)
        raise
      end


      def load_resource_definitions_from_cookbook(cookbook_name)
        files_in_cookbook_by_segment(cookbook_name, :definitions).each do |filename|
          begin
            Chef::Log.debug("Loading cookbook #{cookbook_name}'s definitions from #{filename}")
            resourcelist = Chef::ResourceDefinitionList.new
            resourcelist.from_file(filename)
            definitions.merge!(resourcelist.defines) do |key, oldval, newval|
              Chef::Log.info("Overriding duplicate definition #{key}, new definition found in #{filename}")
              newval
            end
            @events.definition_file_loaded(filename)
          rescue Exception => e
            @events.definition_file_load_failed(filename, e)
            raise
          end
        end
      end

      # Builds up the list of +ordered_cookbooks+ by first recursing through the
      # dependencies of +cookbook+, and then adding +cookbook+ to the list of
      # +ordered_cookbooks+. A cookbook is skipped if it appears in
      # +seen_cookbooks+, otherwise it is added to the set of +seen_cookbooks+
      # before its dependencies are processed.
      def add_cookbook_with_deps(ordered_cookbooks, seen_cookbooks, cookbook)
        return false if seen_cookbooks.key?(cookbook)

        seen_cookbooks[cookbook] = true
        each_cookbook_dep(cookbook) do |dependency|
          add_cookbook_with_deps(ordered_cookbooks, seen_cookbooks, dependency)
        end
        ordered_cookbooks << cookbook
      end


      def count_files_by_segment(segment)
        cookbook_collection.inject(0) do |count, ( cookbook_name, cookbook )|
          count + cookbook.segment_filenames(segment).size
        end
      end

      # Lists the local paths to files in +cookbook+ of type +segment+
      # (attribute, recipe, etc.), sorted lexically.
      def files_in_cookbook_by_segment(cookbook, segment)
        cookbook_collection[cookbook].segment_filenames(segment).sort
      end

      # Yields the name of each cookbook depended on by +cookbook_name+ in
      # lexical sort order.
      def each_cookbook_dep(cookbook_name, &block)
        cookbook = cookbook_collection[cookbook_name]
        cookbook.metadata.dependencies.keys.sort.each(&block)
      end

    end

    attr_reader :node, :cookbook_collection, :definitions

    # Needs to be settable so deploy can run a resource_collection independent
    # of any cookbooks.
    attr_accessor :resource_collection, :immediate_notification_collection, :delayed_notification_collection

    attr_reader :events

    attr_reader :loaded_recipes
    attr_reader :loaded_attributes

    # Creates a new Chef::RunContext object and populates its fields. This object gets
    # used by the Chef Server to generate a fully compiled recipe list for a node.
    #
    # === Returns
    # object<Chef::RunContext>:: Duh. :)
    def initialize(node, cookbook_collection, events)
      @node = node
      @cookbook_collection = cookbook_collection
      @resource_collection = Chef::ResourceCollection.new
      @immediate_notification_collection = Hash.new {|h,k| h[k] = []}
      @delayed_notification_collection = Hash.new {|h,k| h[k] = []}
      @definitions = Hash.new
      @loaded_recipes = {}
      @loaded_attributes = {}
      @events = events

      @node.run_context = self
    end

    def load(run_list_expansion)
      load_libraries_in_run_list_order(run_list_expansion)

      load_lwrps_in_run_list_order(run_list_expansion)
      load_attributes_in_run_list_order(run_list_expansion)

      load_resource_definitions_in_run_list_order(run_list_expansion)

      @events.recipe_load_start(run_list_expansion.recipes.size)
      run_list_expansion.recipes.each do |recipe|
        begin
          include_recipe(recipe)
        rescue Chef::Exceptions::RecipeNotFound => e
          @events.recipe_not_found(e)
          raise
        rescue Exception => e
          path = resolve_recipe(recipe)
          @events.recipe_file_load_failed(path, e)
          raise
        end
      end
      @events.recipe_load_complete
    end

    def resolve_recipe(recipe_name)
      cookbook_name, recipe_short_name = Chef::Recipe.parse_recipe_name(recipe_name)
      cookbook = cookbook_collection[cookbook_name]
      cookbook.recipe_filenames_by_name[recipe_short_name]
    end

    # Looks up an attribute file given the +cookbook_name+ and
    # +attr_file_name+. Used by DSL::IncludeAttribute
    def resolve_attribute(cookbook_name, attr_file_name)
      cookbook = cookbook_collection[cookbook_name]
      raise Chef::Exceptions::CookbookNotFound, "could not find cookbook #{cookbook_name} while loading attribute #{name}" unless cookbook

      attribute_filename = cookbook.attribute_filenames_by_short_filename[attr_file_name]
      raise Chef::Exceptions::AttributeNotFound, "could not find filename for attribute #{attr_file_name} in cookbook #{cookbook_name}" unless attribute_filename

      attribute_filename
    end

    def notifies_immediately(notification)
      nr = notification.notifying_resource
      if nr.instance_of?(Chef::Resource)
        @immediate_notification_collection[nr.name] << notification
      else
        @immediate_notification_collection[nr.to_s] << notification
      end
    end

    def notifies_delayed(notification)
      nr = notification.notifying_resource
      if nr.instance_of?(Chef::Resource)
        @delayed_notification_collection[nr.name] << notification
      else
        @delayed_notification_collection[nr.to_s] << notification
      end
    end

    def immediate_notifications(resource)
      if resource.instance_of?(Chef::Resource)
        return @immediate_notification_collection[resource.name]
      else
        return @immediate_notification_collection[resource.to_s]
      end
    end

    def delayed_notifications(resource)
      if resource.instance_of?(Chef::Resource)
        return @delayed_notification_collection[resource.name]
      else
        return @delayed_notification_collection[resource.to_s]
      end
    end

    def include_recipe(*recipe_names)
      result_recipes = Array.new
      recipe_names.flatten.each do |recipe_name|
        if result = load_recipe(recipe_name)
          result_recipes << result
        end
      end
      result_recipes
    end

    def load_recipe(recipe_name)
      Chef::Log.debug("Loading Recipe #{recipe_name} via include_recipe")

      cookbook_name, recipe_short_name = Chef::Recipe.parse_recipe_name(recipe_name)
      if loaded_fully_qualified_recipe?(cookbook_name, recipe_short_name)
        Chef::Log.debug("I am not loading #{recipe_name}, because I have already seen it.")
        false
      else
        loaded_recipe(cookbook_name, recipe_short_name)

        cookbook = cookbook_collection[cookbook_name]
        cookbook.load_recipe(recipe_short_name, self)
      end
    end

    def loaded_fully_qualified_recipe?(cookbook, recipe)
      @loaded_recipes.has_key?("#{cookbook}::#{recipe}")
    end

    def loaded_recipe?(recipe)
      cookbook, recipe_name = Chef::Recipe.parse_recipe_name(recipe)
      loaded_fully_qualified_recipe?(cookbook, recipe_name)
    end

    def loaded_fully_qualified_attribute?(cookbook, attribute_file)
      @loaded_attributes.has_key?("#{cookbook}::#{attribute_file}")
    end

    def loaded_attribute(cookbook, attribute_file)
      @loaded_attributes["#{cookbook}::#{attribute_file}"] = true
    end

    def load_libraries_in_run_list_order(run_list_expansion)
      @compiler = CookbookCompiler.new(node, cookbook_collection, run_list_expansion, events)
      @compiler.compile_libraries
    end

    def load_attributes_in_run_list_order(run_list_expansion)
      @compiler = CookbookCompiler.new(node, cookbook_collection, run_list_expansion, events)
      @compiler.compile_attributes
    end

    def load_lwrps_in_run_list_order(run_list_expansion)
      @compiler = CookbookCompiler.new(node, cookbook_collection, run_list_expansion, events)
      @compiler.compile_lwrps
    end

    def load_resource_definitions_in_run_list_order(run_list_expansion)
      @compiler = CookbookCompiler.new(node, cookbook_collection, run_list_expansion, events)
      @compiler.compile_resource_definitions
      @definitions = @compiler.definitions
    end

    private

    def loaded_recipe(cookbook, recipe)
      @loaded_recipes["#{cookbook}::#{recipe}"] = true
    end

  end
end
